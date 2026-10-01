// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package jsonnet_iac_test

import (
	"github.com/google/go-cmp/cmp"
	"github.com/google/go-jsonnet"
	"path/filepath"
	"testing"
)

func evaluate(t *testing.T, name, input string) (string, error) {
	t.Helper()
	vm := jsonnet.MakeVM()
	absPath, err := filepath.Abs(".")
	if err != nil {
		t.Fatalf("filepath.Abs(\".\") failed: %v", err)
	}
	parentPath := filepath.Join(absPath, "..")
	vm.Importer(&jsonnet.FileImporter{
		JPaths: []string{absPath, parentPath},
	})
	vm.StringOutput = true
	return vm.EvaluateAnonymousSnippet(name, input)
}

func TestBasicHCL(t *testing.T) {

	testCases := []struct {
		name  string
		input string
		want  string
	}{{
		name: "expression",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest(
				hcl.resource {
					hcllabels:: ["test", "name"],
					exp: hcl.expression("hello"),
				},
			false)`,
		want: `resource "test" "name" {
  exp = hello
}

`,
	}, {
		name: "primitive types",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest(
				hcl.resource {
					hcllabels:: ["test", "name"],
					int: 1,
					bool_true: true,
					bool_false: false,
					str: 'test me with unescaped "quotes" inside and a \n new line',
					str_with_quotes_newlines: hcl.escape_quotes_newlines('test me with "quotes" inside and a \n new line'),
					nuul: null,
				},
			false)`,
		want: `resource "test" "name" {
  bool_false               = false
  bool_true                = true
  int                      = 1
  nuul                     = null
  str                      = "test me with unescaped "quotes" inside and a 
 new line"
  str_with_quotes_newlines = "test me with \"quotes\" inside and a \n new line"
}

`,
	}, {
		name: "escaped backslashes and template markers",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest(
				hcl.resource {
					hcllabels:: ["test", "name"],
					trailing_backslash: hcl.escape_quotes_newlines('C:\\share\\'),
					template_marker: hcl.escape_quotes_newlines('${file("/etc/passwd")}'),
					directive_marker: hcl.escape_quotes_newlines('%{ if true }x%{ endif }'),
				},
			false)`,
		want: `resource "test" "name" {
  directive_marker   = "%%{ if true }x%%{ endif }"
  template_marker    = "$${file(\"/etc/passwd\")}"
  trailing_backslash = "C:\\share\\"
}

`,
	}, {
		name: "dictionary",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest(
				hcl.resource {
					hcllabels:: ["test", "name"],
					block: { prop: "hello" },
				},
			false)`,
		want: `resource "test" "name" {
  block = {
    prop = "hello"
  }
}

`,
	}, {
		name: "nested block",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest(
				hcl.resource {
					hcllabels:: ["test", "name"],
					some_block: hcl.nested_block {},
					foo_block: hcl.block() {},
					ignored_name_block: hcl.block("other_block") {},
				},
			false)`,
		want: `resource "test" "name" {
  foo_block {
  }
  other_block {
  }
  some_block {
  }
}

`,
	}, {
		name: "links",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest({
				resource1: hcl.resource {
					hcllabels:: ["res", "name1"],
					value: 1,
				},
				multi_resource: hcl.resource {
					hcllabels:: ["res", "multi_resource"],
					count: 2,
				},
				data: hcl.data {
					hcllabels:: ["data1", "name"],
				},
				locals: hcl.locals {
					foo: 1,
				},
				variable: hcl.variable("bar") {
					value: 2,
				},
				module: hcl.module {
					hcllabels:: ["module1", "name"],
				},
				local s = self,
				resource2: hcl.resource {
					hcllabels:: ["res", "name2"],
					res1: s.resource1.self_link,
					res1_value: s.resource1.self_ref("value"),
					default_idx: s.multi_resource.self_ref("value"),
					custom_idx: s.multi_resource.self_ref("value", "idx"),
					data: s.data.self_link,
					module: s.module.self_link,
					local_foo: s.locals.self_ref("foo"),
					variable1: s.variable.self_ref(),
				},
			},
			false)`,
		want: `data "data1" "name" {
}

locals {
  foo = 1
}

module "module1" "name" {
}

resource "res" "multi_resource" {
  count = 2
}

resource "res" "name1" {
  value = 1
}

resource "res" "name2" {
  custom_idx  = res.multi_resource[idx].value
  data        = data.data1.name.self_link
  default_idx = res.multi_resource[count.index].value
  local_foo   = local.foo
  module      = module.module1.name.self_link
  res1        = res.name1.self_link
  res1_value  = res.name1.value
  variable1   = var.bar
}

variable "bar" {
  value = 2
}

`,
	}, {
		name: "output",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest({
				local server = hcl.data {
					hcllabels:: ["aws_instance", "server"],
				},
				out: hcl.output("instance_ip_addr") {
					value: server.self_ref("private_ip"),
				},
			},
			false)`,
		want: `output "instance_ip_addr" {
  value = data.aws_instance.server.private_ip
}

`,
	}, {
		name: "array of expressions",
		input: `
      local hcl = import 'hcl.libsonnet';
			local expr1 = hcl.expression("format(%%s expr1, 1)");
			local foo_ref = hcl.variable("foo").self_ref();
			local expr2 = hcl.expression("expr2 + %s", [foo_ref]);
			local expr3 = hcl.expression("expr3 + %s", foo_ref);
			local expr4 = hcl.expression("expr4 + %(name)s + %(v)s", {name: foo_ref, v: 5});
      hcl.manifest(
				hcl.resource {
					hclcomment:: ["comment1"],
					hcllabels:: ["test", "name"],
					arr_field: [expr1, expr2, expr3, expr4],
				},
			true)`,
		want: `# DO NOT EDIT manually. This file was generated by jsonnet.

#comment1
resource "test" "name" {
  arr_field = [
    format(%%s expr1, 1),
    expr2 + var.foo,
    expr3 + var.foo,
    expr4 + var.foo + 5
  ]
}

`,
	}, {
		name: "repeated_block",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest(
				hcl.resource {
					hcllabels:: ["test", "name"],
					boo: hcl.repeated_block() {
						blocks:: [{}],
					},
					some_type: hcl.repeated_block("some_type") {
						blocks:: [
							{
								size: 1,
							},
							{
								size: 2,
							},
						],
					},
				},
			false)`,
		want: `resource "test" "name" {
  boo {
  }
  some_type {
    size = 1
  }
  some_type {
    size = 2
  }
}

`,
	}, {
		name: "resources are sorted",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest([
				hcl.resource { hcllabels:: ["test2", "name3"] },
				hcl.resource { hcllabels:: ["test1", "name2"] },
				hcl.resource { hcllabels:: ["test1", "name1"] },
			], false)`,
		want: `resource "test1" "name1" {
}

resource "test1" "name2" {
}

resource "test2" "name3" {
}

`,
	}, {
		name: "conditional block",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest(
				hcl.resource {
					hcllabels:: ["test", "name"],
					d_block: hcl.conditional_block("d_b", "bool_true") {
						foo: 123,
					},
					d_b_name: hcl.conditional_block(conditional_expression="bool_true") {
						bar: 123,
					},
				},
			false)`,
		want: `resource "test" "name" {
  dynamic "d_b_name" {
    content {
      bar = 123
    }
    for_each = bool_true ? [1] : []
  }
  dynamic "d_b" {
    content {
      foo = 123
    }
    for_each = bool_true ? [1] : []
  }
}

`,
	}, {
		name: "dynamic block",
		input: `
      local hcl = import 'hcl.libsonnet';
			local some_list = hcl.variable('some_list') {
				hcllabels:: ['some_list'],
				type: hcl.expression('list(string)'),
				default: ['abc','123'],
			};
      hcl.manifest(
				hcl.resource {
					hcllabels:: ["test", "name"],
					foo: hcl.dynamic_block("foo") {
						content: hcl.nested_block {
							bar: 123,
						},
						for_each: hcl.expression('var.list'),
					},
					dummy: hcl.dynamic_block("dummy") {
						content: hcl.nested_block {
							something: hcl.block('something'){
								some_number: 12,
								some_string: 'hi',
							},
						},
						for_each: some_list.self_ref(),
					},
				},
			false)`,
		want: `resource "test" "name" {
  dynamic "dummy" {
    content {
      something {
        some_number = 12
        some_string = "hi"
      }
    }
    for_each = var.some_list
  }
  dynamic "foo" {
    content {
      bar = 123
    }
    for_each = var.list
  }
}

`,
	}, {
		name: "generate_imports",
		input: `
      local hcl = import 'hcl.libsonnet';
      local root = {
        res1: hcl.resource {
          hcllabels:: ["type1", "name1"],
          tfimport: "id1",
        },
        nested: {
          res2: hcl.resource {
            hcllabels:: ["type2", "name2"],
            tfimport: "id2",
          },
        },
        an_array: [
          hcl.resource {
            hcllabels:: ["type3", "name3"],
            tfimport: "id3",
          },
        ],
        data1: hcl.data {
            hcllabels:: ["google_project", "project"],
            tfimport: "projects/my-project-id",
        },
      };
      hcl.manifest(hcl.generate_imports(root), false)`,
		want: `import {
  id = "id3"
  to = type3.name3
}

import {
  id = "projects/my-project-id"
  to = data.google_project.project
}

import {
  id = "id2"
  to = type2.name2
}

import {
  id = "id1"
  to = type1.name1
}

`,
	}, {
		name: "generate_imports_single_resource",
		input: `
      local hcl = import 'hcl.libsonnet';
      local root = hcl.resource {
          hcllabels:: ["type1", "name1"],
          tfimport: "id1",
      };
      hcl.manifest(hcl.generate_imports(root), false)`,
		want: `import {
  id = "id1"
  to = type1.name1
}

`,
	}, {
		name: "strToSnake",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest(
				hcl.resource {
					hcllabels:: ["test", "name"],
					snake: hcl.strToSnake("a-b.c/d e@f:g"),
					snake_complex: hcl.strToSnake("${test}User@Domain.com:80/Path/To-Res V1.0"),
				},
			false)`,
		want: `resource "test" "name" {
  snake         = "a_b_c_d_e_f_g"
  snake_complex = "_test_User_Domain_com_80_Path_To_Res_V1_0"
}

`,
	}, {
		name: "formatting",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest(
				hcl.resource {
					hcllabels:: ["test", "name"],
					a_gateways: [{region: "us-central1"}, {region: "us-west4"}], // = sign of this doesn't belong to below alignment group.
					a_short: "val",
					a_long_field: "val",
					b_nested: hcl.nested_block {
						foo: "bar",
					},
					c_short: "val",
					c_array: [1, 2, 3],
					c_very_long_field_name: "val",
					d_array_long_many_elements: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
					e_a_short: "val",
					e_hash: {
						foo: "bar",
					},
					e_long_argument_name: "val",
					f_d_array_long_one_element: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
					f_short: "val",
					g_d_array_long_one: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbb"],
					g_short: "val",
					h_text: hcl.expression(
            |||
							format(
							  "%s.in-addr.arpa.",
							  join(".", reverse(split(".", google_compute_address.alidaeascs51.address)))
							)
          	|||
					),
					h_v: "val",
				},
			false)`,
		want: `resource "test" "name" {
  a_gateways = [{
    region = "us-central1"
    }, {
    region = "us-west4"
  }]
  a_long_field = "val"
  a_short      = "val"
  b_nested {
    foo = "bar"
  }
  c_array                = [1, 2, 3]
  c_short                = "val"
  c_very_long_field_name = "val"
  d_array_long_many_elements = [
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ]
  e_a_short = "val"
  e_hash = {
    foo = "bar"
  }
  e_long_argument_name       = "val"
  f_d_array_long_one_element = ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
  f_short                    = "val"
  g_d_array_long_one = [
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbb"
  ]
  g_short = "val"
  h_text = format(
    "%s.in-addr.arpa.",
    join(".", reverse(split(".", google_compute_address.alidaeascs51.address)))
  )

  h_v = "val"
}

`,
	}, {
		name: "formatting_multiline_expression",
		input: `
      local hcl = import 'hcl.libsonnet';
      hcl.manifest(
				hcl.resource {
					hcllabels:: ["google_monitoring_dashboard", "disaster_recovery_health_issues"],
					dashboard_json: hcl.expression(
						|||
							file(abspath("${path.module}/../../cloud_dashboards/templates/disaster_recovery_health_issues.json"))
						|||
					),
					project: "project_id",
					provider: hcl.expression("google-beta\n"),
				},
			false)`,
		want: `resource "google_monitoring_dashboard" "disaster_recovery_health_issues" {
  dashboard_json = file(abspath("${path.module}/../../cloud_dashboards/templates/disaster_recovery_health_issues.json"))

  project  = "project_id"
  provider = google-beta

}

`,
	},
	}

	for _, cc := range testCases {
		c := cc
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			got, err := evaluate(t, c.name, c.input)
			if err != nil {
				t.Errorf("EvaluateAnonymousSnippet error: %v", err)
			}
			if d := cmp.Diff(c.want, got); d != "" {
				t.Errorf("EvaluateAnonymousSnippet diff (want->got):\n %s", d)
			}
		})
	}

}
