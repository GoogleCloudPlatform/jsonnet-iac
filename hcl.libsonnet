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

// Library to generate HCL (Terraform) content from Jsonnet.
//
// This library provides a set of mixins and functions to model Terraform resources,
// data sources, variables, and other HCL constructs as Jsonnet objects.
//
// CANONICAL USAGE:
//
// 1. Define resources using `hcl.resource`:
//    local hcl = import 'hcl.libsonnet';
//    {
//      my_bucket:: hcl.resource {
//        hcllabels:: ['google_storage_bucket', 'my-bucket'],
//        name: 'my-bucket',
//        location: 'US',
//      }
//    }
//
// 2. Reference resources using `.self_ref()`:
//    {
//      my_object:: hcl.resource {
//        hcllabels:: ['google_storage_bucket_object', 'new-object'],
//        bucket: $.my_bucket.self_ref('name'), // Produces: google_storage_bucket.my-bucket.name
//        name: 'new-object',
//      }
//    }
//
// 3. Generate HCL output using `hcl.manifest()`:
//    {
//      'main.tf': hcl.manifest(self.my_bucket + self.my_object),
//    }
//
// IMPORTANT MIXINS:
//
// * hcl.resource: Defines a Terraform resource. Requires `hcllabels:: [type, name]`.
// * hcl.data: Defines a Terraform data source. Requires `hcllabels:: [type, name]`.
// * hcl.manifest(obj): Converts a Jsonnet object tree into an HCL string.
// * hcl.nested_block: Defines a nested block within a resource (e.g. `lifecycle {}`).
// * hcl.expression(str): Marks a string as a raw HCL expression (not a quoted string).
// * hcl.strToSnake(str): Utility to convert strings to snake_case (useful for resource names).
//
{
  // Creates a terraform expression.
  // See https://developer.hashicorp.com/terraform/language/expressions.
  // Parameters:
  //   e - the expression string
  //   format_args [Optional] - array of values to be uses in string formatting of "e".
  //                 If expression of this lib is passed, it will be unwrappped.
  //                 E.g. hcl.variable('foo') will be var.foo
  //
  // Example:
  // hcl.resource {
  //   hacllabels:: ["test", "name"],
  //   a_field: hcl.expression('%s + 5', [hcl.variable('foo').self_ref()]),
  // }
  // will result in terraform like:
  // resource "test" "name" {
  //  a_field = var.foo + 5
  // }
  // TIP: wrap formatting args with hcl.toString() when it's unclear if argument is a string or terraform expression.
  //      e.g. hcl.toString(hcl.expression('5 + 6')) will result in "${5 + 6}"
  //      e.g. hcl.toString("plain string") will result in "plain string"
  expression(e, format_args=null)::
    local formatted_e =
      if format_args == null then
        e
      else if std.isArray(format_args) then
        e % [
          if std.isObject(a) && 'hcldump' in a then
            a.hcldump('')
          else
            a
          for a in format_args
        ]
      else if std.isObject(format_args) then
        if 'hcldump' in format_args then
          e % format_args.hcldump('')
        else
          e % {
            [f]: if std.isObject(format_args[f]) && 'hcldump' in format_args[f] then
              format_args[f].hcldump('')
            else
              format_args[f]
            for f in std.objectFields(format_args)
          }
      else e % format_args;

    // don't wrap strings into hcl object, leave it just regular string value.
    // (it's a string if there are quotes at the beginning and the end, and no other quotes inside)
    if
      std.startsWith(formatted_e, '"')
      && std.endsWith(formatted_e, '"')
      && std.length(std.findSubstr('"', formatted_e)) == 2
    then std.stripChars(formatted_e, '"')  // '"some value"' -> 'some value'
    else {
      hcldump(k, indent_str='')::
        local s = std.strReplace(formatted_e, '\n', '\n' + indent_str);
        k + if std.endsWith(s, '\n' + indent_str) then std.substr(s, 0, std.length(s) - std.length(indent_str)) else s,
      // See https://developer.hashicorp.com/terraform/language/expressions/strings#interpolation
      interpolation:: '${%s}' % formatted_e,
    },

  // Creates an HCL block with the given type.
  // It is a generic function used to create any HCL block.
  //
  // Parameters:
  //   type [Optional] - the type of the block (e.g. "resource", "data", "locals").
  //                     If type is omitted then it behaves like hcl.nested_block.
  //                     NOTE: use hcl.nested_block instead of hcl.block()
  //                     (though both produce the same result)
  //
  // Example:
  //   hcl.block('boot_disk') {
  //     auto_delete: false,
  //   }
  // will produce:
  //   boot_disk {
  //     auto_delete = false
  //   }
  block(type=null):: if type == null then $.nested_block else {
    // final string representation of the 1st line of the resource,
    // used as a key of this object in sort operation.
    type_labels_string:: '%s %s' % [
      type,
      if 'hcllabels' in self then
        '"' + std.join('" "', self.hcllabels) + '" '
      else '',
    ],
    hcldump(ignored, indent_str='')::
      assert std.isString(type) : 'an HCL block type should be a string';
      _hcldump(
        if indent_str != ''
        then indent_str + std.stripChars(self.type_labels_string, ' ') + ' '
        else self.type_labels_string,
        self,
        top_level_block=true,
        indent_str=indent_str
      ),
    hclcomment:: [],
  },

  // Creates a terraform nested block.
  // It doesn't have an explicit type or hcl labels.
  // The field name in the parent object determines the block name.
  //
  // Example:
  //   hcl.resource {
  //     hcllabels:: ["aws_instance", "example"],
  //     network_interface: hcl.nested_block {
  //       foo: 1,
  //     }
  //   }
  // -- will produce -->
  //   resource "aws_instance" "example" {
  //     network_interface {
  //       foo: 1
  //     }
  //   }
  nested_block: {
    hcldump(prefix, indent_str='')::
      local block_type = std.strReplace(prefix, ' = ', '');
      local labels_string =
        if 'hcllabels' in self then
          '" ' + std.join('" "', self.hcllabels) + '" '
        else ' ';
      _hcldump(block_type + labels_string, self, top_level_block=true, indent_str=indent_str),
  },

  // Creates a dynamic block using a conditional expression to omit content if false.
  //    hcl.conditional_block('foo', 'bar == 1') {
  //      field1: 123,
  //    },
  // will produce:
  //    dynamic "foo" {
  //      for_each = if bar == 1 ? [1] : []
  //      content {
  //        field1: 123,
  //      }
  //    }
  // If "name" is omitted then field name will be used:
  //   some_name: hcl.conditional_block(conditional_expression='bar == 1')...
  //     -- will produce -->
  //   dynamic "some_name" {..
  conditional_block(name=null, conditional_expression='true'): {
    local self_as_content = self,
    hcldump(prefix, indent_str=''):: $.block('dynamic') {
      hcllabels:: [if name == null then std.stripChars(std.strReplace(prefix, ' = ', ''), ' ') else name],
      for_each: $.expression('%s ? [1] : []' % conditional_expression),
      content: self_as_content + $.nested_block,
    }.hcldump(prefix, indent_str=indent_str),
  },

  // Creates a dynamic block.
  // foo: hcl.dynamic_block('foo') {
  //   content: hcl.nested_block {
  //     id: hcl.expression('foo.value["id"]'),
  //     project_id: hcl.expression('foo.value["project_id"]'),
  //   },
  //   for_each: some_list_variable.self_ref(),
  // },
  // Will produce:
  // dynamic "foo" {
  //   content {
  //     id         = foo.value["id"]
  //     project_id = foo.value["project_id"]
  //   }
  //   for_each = var.some_list_variable
  // }
  // TODO: Allow name to be taken from prefix if omitted as a parameter.
  dynamic_block(name): $.block('dynamic') {
    hcllabels:: [name],
  },

  local top_level_block(type, ref_prefix=null) = $.block(type) {
    self_link:: self.self_ref('self_link'),
    self_ref(attr=null, index_expr='count.index'):: $.expression(
      // If attr provided then produces:
      //  <ref_prefix>.<hcl_label1>.<hcl_labelN>.[count.index].<attr>
      //
      // if no attr and no count argument in resource then produces:
      //  <ref_prefix>.<hcl_label1>.<hcl_labelN>
      std.join('.', [ref_prefix] + if 'hcllabels' in self then self.hcllabels else []) +
      // append [count.index] with assumption that by default a link to plural resource created from plural resource.
      (if 'count' in self then '[%s]' % index_expr else '')
      +
      (if attr == null then '' else '.%s' % attr)
    ),
  },

  // Top level block defining resource.
  // (https://developer.hashicorp.com/terraform/language/resources/syntax)
  // Requires hcllabels hidden field to populate resource labels (type and name).
  // It can also contain:
  //   tfimport: string, if provided then "terraform import" comment will be added to result manifest.
  //   tfforceimport: string, if provided then "tfforceimport" comment will be added to result manifest.
  //   hclmoved: array, if provided then "moved" block will be added to result manifest.
  //           The value should be hcllabels of resource being moved FROM.
  // Example:
  //  hcl.resource {
  //    hcllabels:: ["aws_instance", "example"],
  //    ami: "abc123",
  //    tfimport: "i-1234567890abcdef0",
  //    hclmoved: ["aws_instance", "example_former_bad_name"],
  //  }
  //Will produce:
  //  # terraform import aws_instance.example i-1234567890abcdef0
  //
  //  moved {
  //    from = aws_instance.example_former_bad_name
  //    to   = aws_instance.example
  //  }
  //
  //  resource "aws_instance" "example" {
  //    ami = "abc123"
  //  }
  resource:: top_level_block('resource') {
    hclcomment+:: if 'tfimport' in self then
      ['# terraform import %s.%s %s' % (self.hcllabels + [self.tfimport])]
    else if 'tfforceimport' in self then
      ['# tfforceimport %s.%s %s' % (self.hcllabels + [self.tfforceimport])]
    else [],
    hcldump(unused, indent_str='')::
      std.join(
        '\n',
        (if 'hclmoved' in self then [$.moved((self { hcllabels:: self.hclmoved }).self_ref(), self.self_ref()).hcldump(unused, indent_str=indent_str)] else [])
        + [super.hcldump(unused, indent_str=indent_str)]
      ),
  },

  // Top level block defining data source.
  // (https://developer.hashicorp.com/terraform/language/data-sources)
  // Requires hcllabels hidden field to populate data source lables (type and name).
  // Example:
  //  hcl.data {
  //    hcllabels:: ["aws_ami", "example"],
  //    most_recent = true,
  //  }
  //Will produce:
  //  data "aws_ami" "example" {
  //    most_recent = true
  //  }
  data:: top_level_block('data', ref_prefix='data'),

  // Top level block defining module block.
  // (https://developer.hashicorp.com/terraform/language/modules/syntax)
  // Requires hcllabels hidden field to populate module name.
  // Example:
  //  hcl.module {
  //    hcllabels:: ["module_name"],
  //    source: "./app-cluster",
  //  }
  //Will produce:
  //  module "module_name" {
  //    source = "./app-cluster"
  //  }
  module:: top_level_block('module', ref_prefix='module'),

  // Top level block defining input variable.
  // (https://developer.hashicorp.com/terraform/language/values/variables)
  // Example:
  //  hcl.variable("image_id") {
  //    type: hcl.expression("string"),
  //  }
  //Will produce:
  //  variable "image_id" {
  //    type = string
  //  }
  variable(name):: top_level_block('variable', ref_prefix='var') {
    hcllabels:: [name],
  },

  // Top level block defining output variable.
  // (https://developer.hashicorp.com/terraform/language/values/outputs)
  // Example:
  //  hcl.output("instance_ip_addr") {
  //    value: server.self_ref("private_ip"),
  //  }
  //  # where "server" could be defined as below:
  //  local server = hcl.data {
  //    hcllabels:: ["aws_instance", "server"],
  //  },
  //Will produce:
  //  output "instance_ip_addr" {
  //    value = aws_instance.server.private_ip
  //  }
  output(name):: $.block('output') {
    hcllabels:: [name],
  },


  // Top level block defining local values.
  // (https://developer.hashicorp.com/terraform/language/values/locals)
  // Example:
  //  hcl.locals {
  //    service_name: "forum",
  //    owner: "Community Team",
  //  }
  //Will produce:
  //  locals {
  //    service_name = "forum"
  //    owner        = "Community Team"
  //  }
  locals:: top_level_block('locals', ref_prefix='local'),

  // Generates array of import tf resources for all objects
  // with defined tfimport in the root object reccursively.
  // TIP: use it when there are existing resources, and you want import them by running tf apply
  // Example:
  //  local root = {
  //     foo: hcl.resource {
  //       hcllabels:: ["aws_instance", "example"],
  //       tfimport = "aws_ami/example"
  //     }
  //   }
  // Then hcl.generate_imports(root) will produce:
  //  import {
  //    id = "aws_ami/example"
  //    to = aws_instance.example
  //  }
  generate_imports(root):: std.flattenArrays([
    if std.isArray(root) then
      [$.generate_imports(v) for v in root]
    else if std.isObject(root) then
      if 'tfimport' in root then
        [top_level_block('import') {
          id: root.tfimport,
          to: root.self_ref(),
        }]
      else $.generate_imports(std.objectValues(root))
    else [],
  ]),

  // Creates an import block.
  // Arg:
  //   from: the expression of the from resource.
  //   to: the expression of the to resource.
  // Example:
  //   hcl.import_block(
  //     from=hcl.expression('module.foo.google_compute_instance.foo'),
  //     to=self.compute.vm.self_ref(),
  //   ),
  // NOTE: "import" is reserved word, so it can't be used as mixin name.
  import_block(from, to):: $.block('import') {
    id: from,
    to: to,
  },

  // Creates a moved block.
  // Arg:
  //   from: the expression of the from resource.
  //   to: the expression of the to resource.
  // Example:
  //   hcl.moved(
  //     from=hcl.expression('module.foo.google_compute_instance.foo'),
  //     to=self.compute.vm.self_ref(),
  //   ),
  moved(from, to):: $.block('moved') {
    from: from,
    to: to,
  },

  // The repeated nested block.
  // It doesn't have type and hcl labels.
  // Type of the block can be passed as string to repeated_block(<type>)
  //    NOTE: field name is used as type if <type> is not passed.
  // blocks field contains array of each block body.
  // Example:
  //    hcl.resource {
  //      hcllabels:: ["google_compute_instance", "name"],
  //      attached_disk: hcl.repeated_block() {
  //        blocks:: [
  //          {
  //            device_name: hcl.expression("google_compute_disk.d_1.name"),
  //            source: hcl.expression("google_compute_disk.d_1.self_link"),
  //          },
  //          {
  //            device_name: hcl.expression("google_compute_disk.d_2.name"),
  //            source: hcl.expression("google_compute_disk.d_2.self_link"),
  //          },
  //        ],
  //      },
  //    },
  // Will produce:
  //   resource "google_compute_instance" "name" {
  //      attached_disk {
  //        device_name = google_compute_disk.d_1.name
  //        source      = google_compute_disk.d_1.self_link
  //      }
  //      attached_disk {
  //        device_name = google_compute_disk.d_2.name
  //        source      = google_compute_disk.d_2.self_link
  //      }
  //   }
  repeated_block(type=null):: {
    hcldump(prefix, indent_str='')::
      local block_type =
        if type != null then
          type
        else
          std.stripChars(std.strReplace(prefix, ' = ', ''), ' ');
      std.join('\n', [
        ($.block(block_type) + b).hcldump(prefix, indent_str=indent_str)
        for b in self.blocks
      ]),
  },

  // Converts the input to a string.
  // - If the input is an hcl.expression (or has an 'interpolation' field), returns its interpolation string (e.g., "${var.foo}").
  // - Otherwise, converts the input using std.toString().
  //
  // This is useful when you need to use an hcl.expression in string formatting or other string manipulations.
  //
  // Parameters:
  //   o - The object to convert (string, number, boolean, or hcl.expression).
  //
  // Example:
  //   local my_var = hcl.variable('my_var');
  //   {
  //     // Result: "prefix-${var.my_var}"
  //     key: "prefix-%s" % hcl.toString(my_var.self_ref()),
  //
  //     // Result: "some_value" (if my_var was a simple string "some.value")
  //     normalized: std.strReplace(hcl.toString("some.value"), ".", "_"),
  //   }
  toString(o):
    if std.isObject(o) && std.objectHasAll(o, 'interpolation') then o.interpolation
    else std.toString(o),

  // Converts string to snake_case.
  // Convenient for hcllabels: e.g. hcllabels:: ['google_compute_disk', hcl.strToSnake(self.name)]
  // It's a terraform style guide to express resource blocks in snake case.
  strToSnake(str): std.foldl(function(s, c) std.strReplace(s, c, '_'), ['-', '.', '/', ' ', '@', ':', '${', '}'], str),

  // Escapes quotes and newlines in a terraform string.
  // Example:
  //     hcl.resource {
  //       hcllabels:: ["test", "name"],
  //       str: hcl.escape_quotes_newlines('test me with "quotes" inside and a \n new line'),
  //
  // will result in terraform like:
  // resource "test" "name" {
  //  str = "test me with \"quotes\" inside and a \n new line"
  // }
  //
  // Without eascaping it would be:
  // resource "test" "name" {
  // str = "test me with unescaped "quotes" inside and a
  //  new line"
  // }
  escape_quotes_newlines(str):: std.strReplace(std.strReplace(str, '"', '\\"'), '\n', '\\n'),

  // Generates HCL manifest file from the given body.
  // add_comments - optional. Defaults to true.
  //                If true then comments will be added to the manifest file.
  // Example:
  //  local my_config = {
  //    my_instance: hcl.resource {
  //      hcllabels:: ["google_compute_instance", "my-instance"],
  //      name: "my-instance",
  //      machine_type: "e2-medium",
  //    },
  //    my_variable: hcl.variable("my_var") {
  //      type: "string",
  //      default: "default_value",
  //    },
  //  };
  //  hcl.manifest(my_config)
  // Will produce:
  //  # DO NOT EDIT manually. This file was generated by jsonnet.
  //
  //  variable "my_var" {
  //    type    = "string"
  //    default = "default_value"
  //  }
  //
  //  resource "google_compute_instance" "my-instance" {
  //    machine_type = "e2-medium"
  //    name         = "my-instance"
  //  }
  manifest(body, add_comments=true)::
    local collectTopLevelBlocks(value, fields_path='') =
      // The top-level structure is allowed to have arrays and objects,
      // containing arrays and objects, as long as at some level they have hcldump.
      // Only visible (":", not "::") object members are considered.
      if std.isObject(value) then
        if 'hcldump' in value then
          [value]
        else
          std.flattenArrays([
            collectTopLevelBlocks(value[field], fields_path + '.' + field)
            for field in std.objectFields(value)
          ])
      else if std.isArray(value) then
        std.flattenArrays([collectTopLevelBlocks(i, fields_path) for i in value])
      else if value == null then
        []
      else
        error 'No hcldump in any object in the path <top>%s.%s (see hcl.libsonnet for more details)' % [fields_path, value];
    // We want to sort by the value of hcldump, and only then add hclcomment,
    // otherwise we sort by the comments.
    local lines = [
      // A comment runs to the end of the line, so every line of it needs its own '#'.
      std.lines(['#' + std.strReplace(c, '\n', '\n#') for c in x.hclcomment if 'hclcomment' in x && add_comments]) + x.hcldump(null)
      for x in
        std.sort(collectTopLevelBlocks(body), keyF=function(x) if 'type_labels_string' in x then x.type_labels_string else '')
    ];
    // 1 empty line between resources and 1 new line in the end of file.
    (if add_comments then
       '# DO NOT EDIT manually. This file was generated by jsonnet.\n\n'
     else
       '')
    + std.join('\n\n', lines) + '\n',

  // Translates the "value" to terraform.
  // block_prefix    - is the string in front of materialized "value",
  //   e.g. "field_name = " can be preffix of value 123, so result is "field_name = 123"
  // top_level_block - indicates if "hcldump()" method shoud be ignored in current object.
  //   It's needed to top level tf blocks to break reccursive call of hcldump().
  local _hcldump(block_prefix, value, top_level_block=false, indent_str='') =
    if std.isObject(value) then
      _dumpObject(block_prefix, value, top_level_block, indent_str)
    else if std.isArray(value) then
      _dumpArray(block_prefix, value, indent_str)
    else if std.isString(value) then
      '%s"%s"' % [block_prefix, value]
    else '%s%s' % [block_prefix, value],

  local indent = '  ',
  local line_width = 80,

  local _dumpArray(block_prefix, value, indent_str) =
    // Sometimes lists are very long and unreadable.
    // First we try to put all values in one line, and if its too long, we split.
    local st = '[%s]' % [std.join(', ', [_hcldump('', i, indent_str=indent_str) for i in value])];
    if std.length(std.strReplace(block_prefix, indent, '') + st) < line_width
    // caveat: short array of objects miss indentation for "}, {", so we add it here if needed.
    then block_prefix + std.strReplace(st, '}, {\n', indent + '}, {\n')
    else
      local next_indent = indent_str + indent;
      local content = std.join(',\n', [_hcldump(next_indent, i, indent_str=next_indent) for i in value]);
      '%s[\n%s\n%s]' % [block_prefix, content, indent_str],

  local _dumpObject(block_prefix, value, top_level_block, indent_str) =
    if !top_level_block && 'hcldump' in value then
      value.hcldump(block_prefix, indent_str)
    else
      local next_indent = indent_str + indent;
      local groups = _groupFields(value);
      std.lines(
        [block_prefix + '{'] +
        std.flattenArrays([_renderGroup(g, value, next_indent) for g in groups])
      ) + indent_str + '}',

  // Returns:
  //   An array of objects (groups), where each object has:
  //     assign: boolean. If true, these fields are rendered as "key = value" and aligned.
  //     fields: array of strings. The names of the fields in this group.
  //     closed: boolean. Internal flag. If true, the last field in this group ends with
  //             a newline, preventing subsequent fields from being merged into this group.
  local _groupFields(value) =
    local fields = std.objectFields(value);
    std.foldl(
      function(acc, field)
        local v = value[field];
        local info = _get_field_info(field, v);
        if std.length(acc) == 0 then
          [{ assign: info.assign, fields: [field], closed: info.term }]
        else
          local last = acc[std.length(acc) - 1];
          if last.assign && info.assign && !last.closed then
            acc[0:std.length(acc) - 1] + [last {
              fields: last.fields + [field],
              closed: info.term,
            }]
          else
            acc + [{ assign: info.assign, fields: [field], closed: info.term }],
      fields,
      []
    ),

  local _renderGroup(g, value, next_indent) =
    local max_len = std.foldl(function(m, f) std.max(m, std.length(f)), g.fields, 0);
    [
      local pad = if g.assign
      then std.join('', [' ' for i in std.range(1, max_len - std.length(field))])
      else '';
      _hcldump(next_indent + field + pad + ' = ', value[field], top_level_block=false, indent_str=next_indent)
      for field in g.fields
    ],

  // Returns an object describing how the field `f` with value `v` should be rendered.
  //  assign: boolean. If true, the field is rendered as "key = value" and can be part of an aligned group.
  //  term: boolean. If true, the value ends with a newline, closing the alignment group (no subsequent fields will be aligned with this one).
  local _get_field_info(f, v) =
    if std.isObject(v) then
      if 'interpolation' in v then
        {
          assign: std.length(std.findSubstr('\n', v.interpolation)) <= 1,
          term: std.endsWith(v.interpolation, '\n}'),
        }
      else
        { assign: false, term: false }
    else if std.isArray(v) then
      local content = '[%s]' % std.join(', ', [_hcldump('', i) for i in v]);
      local overhead = std.length(f) + 3;  // "field = "
      local newlines = std.length(std.findSubstr('\n', content));
      {
        assign: std.length(content) + overhead < line_width && newlines <= 1,
        term: std.endsWith(content, '\n'),
      }
    else
      // Primitives
      if std.isString(v) then
        { assign: true, term: std.endsWith(v, '\n') }
      else
        { assign: true, term: false },
}
