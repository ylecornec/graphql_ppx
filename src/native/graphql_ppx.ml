open Graphql_ppx_base
open Ppxlib

open Source_pos

open Output_native_utils

let argv = Sys.argv |> Array.to_list

let add_pos delimLength base pos =
  {
    pos_fname = base.pos_fname;
    pos_lnum = base.pos_lnum + pos.line;
    pos_bol = 0;
    pos_cnum = if pos.line = 0 then delimLength + pos.col else pos.col;
  }

let add_loc delimLength base span =
  {
    loc_start = add_pos delimLength base.loc_start (fst span);
    loc_end = add_pos delimLength base.loc_start (snd span);
    loc_ghost = false;
  }

let fmt_lex_err err =
  let open Graphql_lexer in
  match err with
  | Unknown_character ch -> Printf.sprintf "Unknown character %c" ch
  | Unexpected_character ch -> Printf.sprintf "Unexpected character %c" ch
  | Unterminated_string -> Printf.sprintf "Unterminated string literal"
  | Unknown_character_in_string ch -> Printf.sprintf "Unknown character in string literal: %c" ch
  | Unknown_escape_sequence s -> Printf.sprintf "Unknown escape sequence in string literal: %s" s
  | Unexpected_end_of_file -> Printf.sprintf "Unexpected end of query"
  | Invalid_number -> Printf.sprintf "Invalid number"

let fmt_parse_err err =
  let open Graphql_parser in
  match err with
  | Unexpected_token t -> Printf.sprintf "Unexpected token %s" (Graphql_lexer.string_of_token t)
  | Unexpected_end_of_file -> "Unexpected end of query"
  | Lexer_error err -> fmt_lex_err err

let is_prefixed prefix str =
  let i = 0 in
  let len = String.length prefix in
  let j = ref 0 in
  while !j < len && String.unsafe_get prefix !j =
                    String.unsafe_get str (i + !j) do
    incr j
  done;
  (!j = len)

let make_error_expr loc message =
  let ext = Location.Error.to_extension (Location.Error.createf ~loc "%s" message) in
  Ast_helper.Exp.extension ~loc ext

let drop_prefix prefix str =
  let len = String.length prefix in
  let rest = (String.length str) - len in
  String.sub str len rest

let () = Ppx_config.(set_config {
    verbose_logging = (match List.find ((=) "-verbose") argv with
        | _ -> true
        | exception Not_found -> false);
    output_mode = (match List.find ((=) "-ast-out") argv with
        | _ -> Ppx_config.Apollo_AST
        | exception Not_found -> Ppx_config.String);
    verbose_error_handling = (match List.find ((=) "-o") argv with
        | _ -> false
        | exception Not_found -> begin match Sys.getenv "NODE_ENV" with
            | "production" -> false
            | _ -> true
            | exception Not_found -> true
          end);
    apollo_mode = (match List.find ((=) "-apollo-mode") argv with
        | _ -> true
        | exception Not_found -> false);
    root_directory = Sys.getcwd ();
    schema_file = (match List.find (is_prefixed "-schema=") argv with
        | arg -> drop_prefix "-schema=" arg
        | exception Not_found -> "graphql_schema.json");
    raise_error_with_loc = fun loc message ->
      let loc = conv_loc loc in
      raise (Location.Error (Location.Error.createf ~loc "%s" message))
  })

let rewrite_query loc delim query encoders_opt =
  let lexer = Graphql_lexer.make query in
  let delimLength = match delim with | Some s -> 2 + String.length s | None -> 1 in
  let filename =
    let filename = Bytes.of_string loc.loc_start.pos_fname in
    for i = 0 to (Bytes.length filename - 1) do
      if Char.equal (Bytes.get filename i) '/' then
        Bytes.set filename i '_'
    done;
    Bytes.to_string filename
  in
  match Graphql_lexer.consume lexer with
  | Result.Error e -> raise (Location.Error (
      Location.Error.createf ~loc:(add_loc delimLength loc e.span |> conv_loc) "%s" (fmt_lex_err e.item)
    ))
  | Result.Ok tokens ->
    let parser = Graphql_parser.make tokens in
    match Graphql_parser_document.parse_document parser with
    | Result.Error e -> raise (Location.Error (
        Location.Error.createf ~loc:(add_loc delimLength loc e.span |> conv_loc) "%s" (fmt_parse_err e.item)
      ))
    | Result.Ok document ->
      let config = {
        Generator_utils.map_loc = add_loc delimLength loc;
        delimiter = delim;
        full_document = document;
        (*  the only call site of schema, make it lazy! *)
        schema = Lazy.force (Read_schema.get_schema ~filename ());
      } in
      match Validations.run_validators config document with
      | Some errs ->
        Ast_helper.Mod.mk
          (Pmod_structure (List.map (fun (loc, msg) ->
               let loc = conv_loc loc in
               [%stri let _ = [%e make_error_expr loc msg]]) errs))
      | None ->
        let parts = Result_decoder.unify_document_schema config document in
        Output_native_module.generate_modules config parts encoders_opt

let rec get_encoders_module attributes ~loc =
  let rec parse_module_path txt =
    match txt with
    | Lident m -> m
    | Ldot (rest, m) -> Format.sprintf "%s.%s" (parse_module_path rest) m
    | _ ->
       raise (Location.Error (
                  Location.Error.createf ~loc "the encoders attribute accepts an ocaml module, e.g. [%%graphql {| { query |}[@encoders Path.To.Module]]"
         ))
  in
  match attributes with
  | [] -> None
  | {attr_name = {txt = "encoders"; _};
     attr_payload =
       PStr
         [{pstr_desc =
             Pstr_eval
               ({pexp_desc =
                    Pexp_construct ({txt; _}, None);
                 pexp_loc_stack = [];_},_);_}];_}::_
    -> Some (parse_module_path txt)
    |_::rest -> get_encoders_module rest ~loc


let rewrite ~loc ~path:_ expr =
  let open Parsetree in
  match expr with
  | PStr [{ pstr_desc = Pstr_eval ({
      pexp_loc = loc;
      pexp_desc = Pexp_constant (Pconst_string (query, delim));
      pexp_attributes = attributes;
      _ }, _); _ }] ->
    rewrite_query
      (conv_loc_from_ast loc)
      delim
      query
      (get_encoders_module attributes ~loc)

(*   | PStr [ *)
(* { pstr_desc = Pstr_eval ({ *)
(*       pexp_loc = _encoders_loc; *)
(*       pexp_desc = Pexp_constant (Pconst_string (encoders, _encoders_delim)); _ }, _); _ } *)
(* ; { pstr_desc = Pstr_eval ({ *)
(*       pexp_loc = loc; *)
(*       pexp_desc = Pexp_constant (Pconst_string (query, delim)); _ }, _); _ }] -> *)
(*     rewrite_query *)
(*       (conv_loc_from_ast loc) *)
(*       delim *)
(*       query *)
(*       (Some encoders) *)
  | _ -> raise (Location.Error (
      Location.Error.createf ~loc "[%%graphql] accepts a string, e.g. [%%graphql {| { query |}]"
    ))

let () =
  let verbose_logging = ref false in
  let output_mode = ref Ppx_config.String in
  let verbose_error_handling = ref (
    match Sys.getenv "NODE_ENV" with
    | "production" -> false
    | _ -> true
    | exception Not_found -> true )
  in
  let apollo_mode = ref false in
  let schema_file = ref "graphql_schema.json" in

  let args = [
    "-verbose", Arg.Set verbose_logging, "";
    "-ast-out", Arg.Unit (fun () -> output_mode := Ppx_config.Apollo_AST), "";
    "-o", Arg.Clear verbose_error_handling, "";
    "-apollo-mode", Arg.Set apollo_mode, "";
    "-schema", Arg.Set_string schema_file, ""
  ]
  in

  let rewrite ~loc ~path e =
    let () = Ppx_config.set_config {
        verbose_logging = !verbose_logging;
        output_mode = !output_mode;
        verbose_error_handling = !verbose_error_handling;
        apollo_mode = !apollo_mode;
        root_directory = Sys.getcwd ();
        schema_file = !schema_file;
        raise_error_with_loc = fun loc message ->
          let loc = conv_loc loc in
          raise (Location.Error (Location.Error.createf ~loc "%s" message))
      }
    in
    rewrite ~loc ~path e
  in

  List.iter (fun (flag, spec, doc) -> Ppxlib.Driver.add_arg flag spec ~doc)
    args;

  let ext = Extension.declare
      "graphql"
      Extension.Context.module_expr
      Ast_pattern.__
      rewrite
  in

  Ppxlib.Driver.register_transformation ~extensions:[ext] "graphql"
