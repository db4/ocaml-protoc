module P   = Printf
module E   = Exception 
module L   = Logger 
module T   = Ocaml_types
module Enc = Encoding_util

let printf_string_of_field_type = function
  | T.String    -> "s" 
  | T.Float     -> "f"
  | T.Int       -> "i"
  | T.Int32     -> "ld"
  | T.Int64     -> "Ld"
  | T.Bytes     -> "s"
  | T.Bool      -> "b"
  | T.User_defined_type _ -> "s"

let constructor_name s =
  String.capitalize @@ String.lowercase s 

let tag_name s =
  String.capitalize @@ String.lowercase (String.map (function | '.' -> '_' | c -> c ) s) 
  
(** utility function used to generate decode/encode function names 
      which are implemented in [Backend_ocaml_static].
 *)
let fname_of_payload_kind = function 
  | Enc.Varint zigzag -> if zigzag then "varint_zigzag" else "varint"
  | Enc.Bits32        -> "bits32"
  | Enc.Bits64        -> "bits64"
  | Enc.Bytes         -> "bytes"

let string_of_field_type ?type_qualifier:(type_qualifier = T.No_qualifier) field_type = 
  let s = match field_type with 
    | T.String -> "string"
    | T.Float  -> "float"
    | T.Int    -> "int"
    | T.Int32  -> "int32"
    | T.Int64  -> "int64"
    | T.Bytes  -> "bytes"
    | T.Bool   -> "bool"
    | T.User_defined_type t -> t
  in
  match type_qualifier with 
  | T.No_qualifier -> s 
  | T.Option       -> s ^ " option"
  | T.List         -> s ^ " list"

let caml_file_name_of_proto_file_name proto = 
  let splitted = Util.rev_split_by_char '.' proto in 
  if List.length splitted < 2 || 
     List.hd splitted <> "proto" 
  then failwith "Proto file has no valid extension"
  else 
    String.concat "_" @@ List.rev @@ ("pb" :: (List.tl splitted)) 

let sp x =  P.sprintf ("\n" ^^ x)  
(** [sp x] same as sprintf but prefixed with new line *)

let nl s = "\n" ^ s  
(** [nl s] appends new line *)

let concat = Util.concat 

let add_indentation n s = 
  Str.global_replace (Str.regexp "^" ) (String.make (n * 2) ' ') s  
(** [add_indentation n s] adds a multiple of 2 spaces indentation to [s] *)

let type_decl_of_and = function | Some _ -> "and" | None -> "type" 

let let_decl_of_and = function | Some _ -> "and" | None -> "let rec" 

let gen_type_record ?and_ {T.record_name; fields } = 
  concat [
    P.sprintf "%s %s = {" (type_decl_of_and and_) record_name;
    concat @@ List.map (fun {T.field_name; field_type; type_qualifier; _ } -> 
      let type_name = string_of_field_type ~type_qualifier field_type in 
      sp "  %s : %s;" field_name type_name
    ) fields;
    "\n}"
  ]

let gen_type_variant ?and_ {T.variant_name; constructors } = 
  concat [
    P.sprintf "%s %s =" (type_decl_of_and and_) variant_name; 
    concat @@ List.map (fun {T.field_name; field_type; type_qualifier; _ } -> 
      let type_name = string_of_field_type ~type_qualifier field_type in 
      sp "  | %s of %s" field_name type_name
    ) constructors;
  ]

let gen_type_const_variant ?and_ {T.variant_name; constructors } = 
  concat [
    P.sprintf "%s %s =" (type_decl_of_and and_) variant_name; 
    concat @@ List.map (fun (name, _ ) -> 
      sp "  | %s " name
    ) constructors;
  ]

let gen_type ?and_ = function 
  | {T.spec = T.Record r; _ } -> gen_type_record ?and_ r 
  | {T.spec = T.Variant v; _ } -> gen_type_variant  ?and_ v 
  | {T.spec = T.Const_variant v; _ } -> gen_type_const_variant ?and_ v 

(** [gen_mappings_record r] generates a per record variable to hold the 
    mapping between a field number and the associated decoding routine. 

    Because the order of fields inside the protobuffer message is not
    guaranteed, the decoding cannot be done in one step.   
    The decoding code must therefore first collect all the record fields 
    values and then create the value of the OCaml type. 
  *)
let gen_mappings_record {T.record_name; fields} =

  let match_cases ?constructor field_number tag_name decode_statement = 
    let left, right = match constructor with
      | Some x -> P.sprintf "(%s " x, ")" 
      | None   -> "", ""
    in 
    concat [
      sp "| %i, `%s l -> `%s (%s (%s)%s::l)"
        field_number 
        tag_name
        tag_name
        left 
        decode_statement 
        right; 
      sp "| %i, `Default -> `%s (%s (%s)%s::[])"
        field_number 
        tag_name
        left
        decode_statement
        right;
    ] 
  in  

  (* When a user defined type belongs to another OCaml module, the corresponding 
     call to its encode function must be preceeded with its OCaml module. 
   *)
  let decode_function_name_of_user_defined t = function 
    | Enc.Other_file {Enc.file_name; type_name} -> 
      let module_ = Backend_ocaml.module_of_file_name file_name in 
      P.sprintf "%s.decode_%s" module_ (String.lowercase type_name) 
    | _ -> 
      P.sprintf "decode_%s" t 
  in 

  concat [
    P.sprintf "let %s_mappings d = function " record_name;
    concat @@ List.map (fun {T.encoding_type;field_type;_ } -> 
      match encoding_type with 
      | T.Regular_field {
        Enc.field_number; 
        Enc.payload_kind;
        Enc.location;
        Enc.nested } -> (
        let decoding = match field_type with 
          | T.User_defined_type t -> 
            let f_name = decode_function_name_of_user_defined t location in
            if nested 
            then  
              match_cases field_number (tag_name t) (f_name ^ " (Pbrt.Decoder.nested d)")
            else 
              match_cases field_number (tag_name t) (f_name ^ " d") 
          | _ -> 
             match_cases field_number (tag_name (string_of_field_type field_type)) 
               (Backend_ocaml_static.runtime_function (`Decode, payload_kind, field_type) ^ " d")
        in 
        P.sprintf "  %s" decoding 
      )
      | T.One_of {T.variant_name ; constructors; } -> (
        concat @@ List.map (fun {T.encoding_type; field_type; field_name; type_qualifier = _ } -> 
          let {
            Enc.field_number; 
            Enc.payload_kind;
            Enc.nested; 
            Enc.location; } = encoding_type in 
          let decoding  =  match field_type with 
            | T.User_defined_type t -> 
              let f_name = decode_function_name_of_user_defined t location in
              if nested 
              then 
                match_cases ~constructor:field_name 
                  field_number 
                  (tag_name variant_name) 
                  (f_name ^ " (Pbrt.Decoder.nested d)")
              else 
                match_cases ~constructor:field_name
                  field_number 
                  (tag_name variant_name) 
                  (f_name ^ " d")
            | _ -> 
              match_cases ~constructor:field_name  
                field_number 
                (tag_name variant_name) 
                (Backend_ocaml_static.runtime_function (`Decode, payload_kind, field_type) ^ " d")
          in 
          P.sprintf "  %s" decoding 
        ) constructors (* All variant constructors *) 
      )                (* One_of record field *)    
    ) fields ;
    sp "| _ -> raise Not_found ";
    "\n";
  ]

let max_field_number fields = 
  List.fold_left (fun max_so_far {T.encoding_type; _ } -> 
    match encoding_type with
    | T.Regular_field {Enc.field_number; _ } -> max max_so_far field_number 
    | T.One_of {T.constructors; _ } -> 
        List.fold_left (fun max_so_far {T.encoding_type = {Enc.field_number; _ } ; _ } -> 
          max field_number max_so_far 
        ) max_so_far constructors 
  ) (- 1) fields

let gen_decode_record ?and_ ({T.record_name; fields } as record) = 
  concat [
    P.sprintf "%s decode_%s =" (let_decl_of_and and_) record_name;
    sp "%s" (add_indentation 1 @@ gen_mappings_record record); 
    sp "  in";
    sp "  (fun d ->"; 
    sp "    let a = Array.make %i (`Default) in " (max_field_number fields  + 1); 
    sp "    Pbrt.Codegen.decode d %s_mappings a; {" record_name;
    add_indentation 3 @@ concat @@ List.map (fun field -> 
      let {
        T.encoding_type;
        T.field_type; 
        T.field_name; 
        T.type_qualifier;
      } = field in 
      match encoding_type with 
      | T.Regular_field {Enc.field_number; _ } -> ( 
          let constructor = tag_name (string_of_field_type field_type) in  
          match type_qualifier with
          | T.No_qualifier -> 
            sp "%s = Pbrt.Codegen.required %i a (function | `%s __v -> __v | _ -> Pbrt.Codegen.programatic_error %i);"
              field_name field_number constructor field_number 
          | T.Option -> 
            sp "%s = Pbrt.Codegen.optional %i a (function | `%s __v -> __v | _ -> Pbrt.Codegen.programatic_error %i);"
              field_name field_number constructor field_number 
          | T.List -> 
            sp "%s = Pbrt.Codegen.list_ %i a (function | `%s __v -> __v | _ -> Pbrt.Codegen.programatic_error %i);"
              field_name field_number constructor field_number
      )
      | T.One_of {T.constructors; variant_name} -> 
          let all_numbers = concat @@ List.map (fun {T.encoding_type= {Enc.field_number; _ } ; _ } -> 
            (P.sprintf "%i;" field_number)
          ) constructors in 
          let all_numbers = concat ["["; all_numbers; "]"] in 
          sp "%s = Pbrt.Codegen.oneof %s a (function | `%s __v -> __v | _ -> Pbrt.Codegen.programatic_error (- 1));"
            field_name all_numbers (tag_name variant_name) 
    ) fields;
    sp "    }";
    sp "  )";
  ]

let gen_decode_const_variant ?and_ {T.variant_name; constructors; } = 
  concat [
    P.sprintf "%s decode_%s d = " (let_decl_of_and and_) variant_name; 
    sp "  match Pbrt.Decoder.int_as_varint d with";
    concat @@ List.map (fun (name, value) -> 
      sp "  | %i -> %s" value name
    ) constructors; 
    sp "  | _ -> failwith \"Unknown value for enum %s\"" variant_name; 
  ] 

let gen_decode ?and_ = function 
  | {T.spec = T.Record r; _ } -> Some (gen_decode_record ?and_ r)
  | {T.spec = T.Variant _; _ } -> None
  | {T.spec = T.Const_variant v; _ } -> Some (gen_decode_const_variant ?and_ v)

let gen_decode_sig t = 
  
  let f type_name = 
    concat [
      P.sprintf "val decode_%s : Pbrt.Decoder.t -> %s" 
        type_name type_name ;
      sp "(** [decode_%s decoder] decodes a [%s] value from [decoder] *)"
        type_name type_name; 
    ]
  in 

  match t with 
  | {T.spec = T.Record {T.record_name ; _ } } ->  Some (f record_name)
  | {T.spec = T.Variant _ } -> None
  | {T.spec = T.Const_variant {T.variant_name; _ } } -> Some (f variant_name)

let gen_encode_record ?and_ {T.record_name; fields } = 
  L.log "gen_encode_record record_name: %s\n" record_name; 

  let gen_field ?indent v_name encoding_type field_type = 
    let {
      Enc.field_number; 
      Enc.payload_kind; 
      Enc.location; 
      Enc.nested} = encoding_type in 
    let s = concat [
      sp "Pbrt.Encoder.key (%i, Pbrt.%s) encoder; " 
        field_number (constructor_name @@ Enc.string_of_payload_kind payload_kind);
      match field_type with 
      | T.User_defined_type t -> 
        let f_name = match location with 
          | Enc.Other_file {Enc.file_name; type_name} -> 
            let module_ = Backend_ocaml.module_of_file_name file_name in 
            P.sprintf "%s.encode_%s" module_ (String.lowercase type_name) 
          | _ -> 
            P.sprintf "encode_%s" t 
        in 
        if nested
        then 
          sp "Pbrt.Encoder.nested (%s %s) encoder;" f_name v_name 
        else 
          sp "%s %s encoder;" f_name v_name 
      | _ ->  
        let rt = Backend_ocaml_static.runtime_function (`Encode, payload_kind, field_type) in 
        sp "%s %s encoder;" rt v_name ;
    ] in 
    match indent with 
    | Some _ -> add_indentation 1 @@ s 
    | None   -> s 
  in

  concat [
    P.sprintf "%s encode_%s v encoder = " (let_decl_of_and and_) record_name;
    add_indentation 1 @@ concat @@ List.map (fun field -> 
      L.log "gen_code field_name: %s\n" field.T.field_name;

      let { T.encoding_type; field_type; field_name; type_qualifier ; } = field in 
      match encoding_type with 
      | T.Regular_field encoding_type -> ( 
        match type_qualifier with 
        | T.No_qualifier -> (
          let v_name = P.sprintf "v.%s" field_name in 
          gen_field v_name encoding_type field_type
        )
        | T.Option -> concat [
          sp "(match v.%s with " field_name;
          sp "| Some x -> (%s)"
          (gen_field ~indent:() "x" encoding_type field_type) ;
          sp "| None -> ());" ;
        ]
        | T.List -> concat [ 
          sp "List.iter (fun x -> ";
          gen_field ~indent:() "x" encoding_type field_type;
          sp ") v.%s;" field_name; 
        ]
      )
      | T.One_of {T.constructors; variant_name = _} -> (  
        concat [
          sp "(match v.%s with" field_name;
          concat @@ List.map (fun {T.encoding_type; field_type; field_name; type_qualifier= _ } ->
              let encode_field  = gen_field ~indent:() "x" encoding_type field_type in 
              sp "| %s x -> (%s\n)" field_name encode_field
          ) constructors;
          ");";
        ]
      )           (* one of        *)
    ) fields;  (* record fields *) 
  "\n  ()"
  ]

let gen_encode_const_variant ?and_ {T.variant_name; constructors; } = 
  concat [
    P.sprintf "%s encode_%s v encoder =" (let_decl_of_and and_) variant_name; 
    sp "  match v with";
    concat @@ List.map (fun (name, value) -> 
      sp "  | %s -> Pbrt.Encoder.int_as_varint %i encoder" name value
    ) constructors; 
  ] 

let gen_encode ?and_ = function 
  | {T.spec = T.Record r }        -> Some (gen_encode_record  ?and_ r)
  | {T.spec = T.Variant _ }       -> None 
  | {T.spec = T.Const_variant v } -> Some (gen_encode_const_variant ?and_ v)

let gen_encode_sig t = 
  let f type_name = 
  concat [
    P.sprintf "val encode_%s : %s -> Pbrt.Encoder.t -> unit"
      type_name
      type_name;
    sp "(** [encode_%s v encoder] encodes [v] with the given [encoder] *)" 
      type_name  
  ]
  in 
  match t with 
  | {T.spec = T.Record {T.record_name ; _ } }-> Some (f record_name)
  | {T.spec = T.Variant _ } -> None
  | {T.spec = T.Const_variant {T.variant_name; _ } } -> Some (f variant_name) 

let gen_string_of_record  ?and_ {T.record_name; fields } = 
  L.log "gen_string_of, record_name: %s\n" record_name; 

  let gen_field field_name field_type encoding_type = 
    match field_type with 
    | T.User_defined_type t -> (
      match encoding_type with
      | {Enc.location = Enc.Other_file {Enc.file_name;type_name} ; _ } -> 
        let module_   = Backend_ocaml.module_of_file_name file_name in 
        let type_name = String.lowercase type_name in  
        P.sprintf "P.sprintf \"\\n%s: %%s\" @@ %s.string_of_%s x" field_name module_ type_name 
      | _ -> 
        P.sprintf "P.sprintf \"\\n%s: %%s\" @@ string_of_%s x" field_name t  
    )
    | _ ->  
      P.sprintf "P.sprintf \"\\n%s: %%%s\" x"  
        field_name 
        (printf_string_of_field_type field_type)
  in

  concat [
    P.sprintf "%s string_of_%s v = " (let_decl_of_and and_) record_name;
    "\n  add_indentation 1 @@ String.concat \"\" [";
    add_indentation 2 @@ concat @@ List.map (fun field -> 
      L.log "gen_string_of field_name: %s\n" field.T.field_name;
     
      let { T.field_type; field_name; type_qualifier ; encoding_type} = field in 
      match encoding_type with 
      | T.Regular_field encoding_type -> ( 
        match type_qualifier with
        | T.No_qualifier -> 
          let field_string_of = gen_field field_name field_type encoding_type in 
          sp "(let x = v.%s in %s);" field_name field_string_of 
        | T.Option -> 
          concat [
            sp "(match v.%s with " field_name;
            sp "| Some x -> (%s)"  (gen_field field_name field_type encoding_type);
            sp "| None -> \"\\n%s: None\");" field_name;
          ]
        | T.List -> 
          concat [
            sp "String.concat \"\" @@ List.map (fun x ->";
            nl @@ gen_field field_name field_type encoding_type; 
            sp ") v.%s;" field_name
          ]
      )
      | T.One_of {T.constructors; variant_name = _} -> (
        concat [
          sp "(match v.%s with" field_name;
          concat @@ List.map (fun {T.encoding_type; field_type; field_name;
          type_qualifier= _ } ->
            let field_string_of = gen_field field_name field_type encoding_type in 
            sp "| %s x -> (%s)" field_name (add_indentation 1 field_string_of)
          ) constructors ;
          "\n);"       (* one of fields *) 
        ]
      )                (* one of        *)
    ) fields;          (* record fields *) 
    "\n  ]";
  ]

let gen_string_of_const_variant ?and_ {T.variant_name; constructors; } = 
  concat [
    P.sprintf "%s string_of_%s v =" (let_decl_of_and and_) variant_name; 
    sp "  match v with";
    concat @@ List.map (fun (name, _ ) -> 
      sp "  | %s -> \"%s\"" name name
    ) constructors; 
  ] 

let gen_string_of ?and_ = function 
  | {T.spec = T.Record r  } -> Some (gen_string_of_record ?and_ r) 
  | {T.spec = T.Variant _ } -> None
  | {T.spec = T.Const_variant v } -> Some (gen_string_of_const_variant ?and_ v)

let gen_string_of_sig t = 
  let f type_name =  
     concat [
       P.sprintf "val string_of_%s : %s -> string " type_name type_name;
       sp "(** [string_of_%s v] returns a debugging string for [v] *)" type_name;
     ]
  in 
  match t with 
  | {T.spec = T.Record {T.record_name ; _ } }-> Some (f record_name)
  | {T.spec = T.Variant _ } -> None
  | {T.spec = T.Const_variant {T.variant_name; _ ; } } -> Some (f variant_name) 
