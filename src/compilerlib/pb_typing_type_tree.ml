(*
  The MIT License (MIT)
  
  Copyright (c) 2016 Maxime Ransan <maxime.ransan@gmail.com>
  
  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.

*)

module Pt = Pb_parsing_parse_tree

(** Protobuf typed tree. 

    The typetree type is parametrized to allow for 2 phase compilation. 
 *)

(** Scope path of a type used for a message field.
    
    For instance in the following field defintion:

    [required foo.bar.Msg1 f = 1]

    The [type_path] would be [\["foo"; "bar"\]]
  *)
type type_path = string list 

(** In the first phase of the compilation 
    the field of message type are not resolved but only 
    properly parsed. 
    
    The following type summarizes the information of a field
    type. 

    In the following field definition:
    
    [required foo.bar.Msg1 f = 1] 

    The unresolved type would be: [{
      scope=\["foo";"bar"\]; 
      type_name="Msg1"; 
      from_root = false
    }]
 *)
type unresolved = {
  type_path : type_path; 
  type_name : string; 
  from_root : bool;  (** from_root indicates that the scope for the type is
                         from the root of the type system. (ie starts with '.')
                      *) 
}

(** After phase 2 compilation the field type is resolved to an 
    known message which can be uniquely identified by its id.
  *)
type resolved = int 

(** Floating point builtin types *)
type builtin_type_floating_point = [ 
  | `Double 
  | `Float 
]

(** Unsigned integer builtin types *)
type builtin_type_unsigned_int  = [
  | `Uint32 
  | `Uint64
]

(** Signed integer builtin types *) 
type builtin_type_signed_int = [
  | `Int32 
  | `Int64 
  | `Sint32 
  | `Sint64 
  | `Fixed32 
  | `Fixed64 
  | `Sfixed32 
  | `Sfixed64 
]

(** Integer builtin types *)
type builtin_type_int= [ 
  |  builtin_type_unsigned_int 
  |  builtin_type_signed_int
]

(** Builtin type defined in protobuf *)
type builtin_type = [
  | builtin_type_floating_point
  | builtin_type_int
  | `Bool 
  | `String 
  | `Bytes 
]

(** field type. 
    
    The ['a] type is for re-using the same type 
    definition for the 2 compilation phases. 
    
    After Phase 1 ['a] is [unresolved] while after Phase2
    ['a] is [resolved].
  *)
type 'a field_type = [ 
  | builtin_type          
  | `User_defined of 'a   (** Message or Enum type *)
]  

(** Field definition. 
    
    {ul
    {- ['a] is for [unresolved] or [resolved]}
    {- ['b] is for [field_label] to account for both normal and one of fields.}
    } *)
type ('a, 'b) field = {
  field_parsed : 'b Pt.field; 
  field_type : 'a field_type; 
  field_default : Pt.constant option; 
  field_options : Pt.field_options; 
}

type 'a oneof_field = ('a, Pt.oneof_field_label) field 

type 'a message_field = ('a, Pt.message_field_label) field  

(** Map definition *)
type 'a map = {
  map_name : string;
  map_number : int;
  map_key_type : 'a field_type;
  map_value_type : 'a field_type;
  map_options : Pt.field_options;
}

(** Oneof definition *)
type 'a oneof = {
  oneof_name : string; 
  oneof_fields : 'a oneof_field list; 
}

(** Type scope 
      
    The scope of a type (message or enum) is defined by the package 
    (defined in the top of the proto file as well as the messages above 
    it since a message definition can be nested *)
type type_scope = {
  packages : string list; 
  message_names : string list; 
}

(** item for the message body *)
type 'a message_body_content = 
  | Message_field       of 'a message_field 
  | Message_oneof_field of 'a oneof 
  | Message_map_field   of 'a map

and 'a message = {
  extensions : Pt.extension_range list;
  message_options : Pt.message_option list;
  message_name : string; 
  message_body : 'a message_body_content list; 
}

type enum_value = {
  enum_value_name: string; 
  enum_value_int : int;
}

type enum = {
  enum_name : string; 
  enum_values: enum_value list; 
  enum_options : Pt.message_option list; 
}

type 'a proto_type_spec = 
  | Enum    of enum 
  | Message of 'a message

type 'a proto_type  = {
  scope : type_scope;
  id :  int; 
  file_name : string; 
  file_options : Pt.file_option list;
  spec : 'a proto_type_spec;
}

type 'a proto = 'a proto_type list 

