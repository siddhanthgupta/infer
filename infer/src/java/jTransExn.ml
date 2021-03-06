(*
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

open Javalib_pack
open Sawja_pack

module E = Logging

let create_handler_table impl =
  let handler_tb = Hashtbl.create 1 in
  let collect (pc, exn_handler) =
    try
      let handlers = Hashtbl.find handler_tb pc in
      Hashtbl.replace handler_tb pc (exn_handler:: handlers)
    with Not_found ->
      Hashtbl.add handler_tb pc [exn_handler] in
  IList.iter collect (JBir.exception_edges impl);
  handler_tb

let translate_exceptions context exit_nodes get_body_nodes handler_table =
  let catch_block_table = Hashtbl.create 1 in
  let exn_message = "exception handler" in
  let procdesc = JContext.get_procdesc context in
  let cfg = JContext.get_cfg context in
  let create_node loc node_kind instrs = Cfg.Node.create cfg loc node_kind instrs procdesc in
  let ret_var = Cfg.Procdesc.get_ret_var procdesc in
  let ret_type = Cfg.Procdesc.get_ret_type procdesc in
  let id_ret_val = Ident.create_fresh Ident.knormal in
  let id_exn_val = Ident.create_fresh Ident.knormal in (* this is removed in the true branches, and in the false branch of the last handler *)
  let create_entry_node loc =
    let instr_get_ret_val = Sil.Letderef (id_ret_val, Sil.Lvar ret_var, ret_type, loc) in
    let id_deactivate = Ident.create_fresh Ident.knormal in
    let instr_deactivate_exn = Sil.Set (Sil.Lvar ret_var, ret_type, Sil.Var id_deactivate, loc) in
    let instr_unwrap_ret_val =
      let unwrap_builtin = Sil.Const (Const.Cfun ModelBuiltins.__unwrap_exception) in
      Sil.Call
        ([id_exn_val], unwrap_builtin, [(Sil.Var id_ret_val, ret_type)], loc, CallFlags.default) in
    create_node
      loc
      Cfg.Node.exn_handler_kind
      [instr_get_ret_val; instr_deactivate_exn; instr_unwrap_ret_val] in
  let create_entry_block handler_list =
    try
      ignore (Hashtbl.find catch_block_table handler_list)
    with Not_found ->
      let collect succ_nodes rethrow_exception handler =
        let catch_nodes = get_body_nodes handler.JBir.e_handler in
        let loc = match catch_nodes with
          | n:: _ -> Cfg.Node.get_loc n
          | [] -> Location.dummy in
        let exn_type =
          let class_name =
            match handler.JBir.e_catch_type with
            | None -> JBasics.make_cn "java.lang.Exception"
            | Some cn -> cn in
          match JTransType.get_class_type (JContext.get_program context) (JContext.get_tenv context) class_name with
          | Typ.Tptr (typ, _) -> typ
          | _ -> assert false in
        let id_instanceof = Ident.create_fresh Ident.knormal in
        let instr_call_instanceof =
          let instanceof_builtin = Sil.Const (Const.Cfun ModelBuiltins.__instanceof) in
          let args = [
            (Sil.Var id_exn_val, Typ.Tptr(exn_type, Typ.Pk_pointer));
            (Sil.Sizeof (exn_type, None, Subtype.exact), Typ.Tvoid)] in
          Sil.Call ([id_instanceof], instanceof_builtin, args, loc, CallFlags.default) in
        let if_kind = Sil.Ik_switch in
        let instr_prune_true = Sil.Prune (Sil.Var id_instanceof, loc, true, if_kind) in
        let instr_prune_false =
          Sil.Prune (Sil.UnOp(Unop.LNot, Sil.Var id_instanceof, None), loc, false, if_kind) in
        let instr_set_catch_var =
          let catch_var = JContext.set_pvar context handler.JBir.e_catch_var ret_type in
          Sil.Set (Sil.Lvar catch_var, ret_type, Sil.Var id_exn_val, loc) in
        let instr_rethrow_exn =
          Sil.Set (Sil.Lvar ret_var, ret_type, Sil.Exn (Sil.Var id_exn_val), loc) in
        let node_kind_true = Cfg.Node.Prune_node (true, if_kind, exn_message) in
        let node_kind_false = Cfg.Node.Prune_node (false, if_kind, exn_message) in
        let node_true =
          let instrs_true = [instr_call_instanceof; instr_prune_true; instr_set_catch_var] in
          create_node loc node_kind_true instrs_true in
        let node_false =
          let instrs_false = [instr_call_instanceof; instr_prune_false] @ (if rethrow_exception then [instr_rethrow_exn] else []) in
          create_node loc node_kind_false instrs_false in
        Cfg.Node.set_succs_exn cfg node_true catch_nodes exit_nodes;
        Cfg.Node.set_succs_exn cfg node_false succ_nodes exit_nodes;
        let is_finally = handler.JBir.e_catch_type = None in
        if is_finally
        then [node_true] (* TODO (#4759480): clean up the translation so prune nodes are not created at all *)
        else [node_true; node_false] in
      let is_last_handler = ref true in
      let process_handler succ_nodes handler = (* process handlers starting from the last one *)
        let remove_temps = !is_last_handler in (* remove temporary variables on last handler *)
        is_last_handler := false;
        collect succ_nodes remove_temps handler in

      let nodes_first_handler =
        IList.fold_left process_handler exit_nodes (IList.rev handler_list) in
      let loc = match nodes_first_handler with
        | n:: _ -> Cfg.Node.get_loc n
        | [] -> Location.dummy in
      let entry_node = create_entry_node loc in
      Cfg.Node.set_succs_exn cfg entry_node nodes_first_handler exit_nodes;
      Hashtbl.add catch_block_table handler_list [entry_node] in
  Hashtbl.iter (fun _ handler_list -> create_entry_block handler_list) handler_table;
  catch_block_table

let create_exception_handlers context exit_nodes get_body_nodes impl =
  match JBir.exc_tbl impl with
  | [] -> fun _ -> exit_nodes
  | _ ->
      let handler_table = create_handler_table impl in
      let catch_block_table = translate_exceptions context exit_nodes get_body_nodes handler_table in
      fun pc ->
        try
          let handler_list = Hashtbl.find handler_table pc in
          Hashtbl.find catch_block_table handler_list
        with Not_found ->
          exit_nodes
