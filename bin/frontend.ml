module Loc = Dolmen.Std.Loc
module E = Dolmen.Std.Expr
module Term = Dolmen.Std.Expr.Term
module Ty = Dolmen.Std.Expr.Ty
module B = Dolmen.Std.Builtin

module Loop = struct
  module State = Dolmen_loop.State
  module Pipeline = Dolmen_loop.Pipeline.Make (State)
  module Parser = Dolmen_loop.Parser.Make (State)
  module Typer = Dolmen_loop.Typer.Typer (State)
  module Flow = Dolmen_loop.Flow.Make (State)
  module Typer_Pipe = Dolmen_loop.Typer.Make (E) (E.Print) (State) (Typer)
end

let unsupported_statement =
  Dolmen_loop.Report.Error.mk ~mnemonic:"unsupported-statement"
    ~message:(fun ppf what ->
      Fmt.pf ppf "Unsupported statement: %s; aborting." what)
    ~name:"Unsupported statement" ()

let nra_solver_key : Nra_solver.t Loop.State.key =
  Loop.State.create_key ~pipe:"nra" "nra_solver"

let var_tag = Dolmen.Std.Tag.create ()

let process_term ~const ~app ?file ?loc st solver (defn : Term.t) =
  match defn.term_descr with
  | Var _ ->
      (* Note: this is a variable in a binder or function definition. Top-level
         variables are called constants in SMT. *)
      Loop.State.error ?file ?loc st unsupported_statement "variable"
  | Cst cst -> const ?file ?loc st solver cst
  | App (fn, _tyvs, xs) ->
      let fn =
        match fn.term_descr with
        | Cst cst -> cst
        | _ ->
            Loop.State.error ?file ?loc st unsupported_statement
              "non-constant application"
      in
      app ?file ?loc st solver fn xs
  | Binder _ ->
      Loop.State.error ?file ?loc st unsupported_statement
        "binder or quantifier"
  | Match _ ->
      Loop.State.error ?file ?loc st unsupported_statement "pattern-matching"

let rec process_bool_term ?file ?loc st solver defn =
  match Ty.view (Term.ty defn) with
  | `Prop ->
      process_term ~const:process_bool_const ~app:process_bool_app ?file ?loc st
        solver defn
  | _ -> Loop.State.error ?file ?loc st unsupported_statement "non-boolean term"

and process_real_term ?file ?loc st solver defn =
  match Ty.view (Term.ty defn) with
  | `Real ->
      process_term ~const:process_real_const ~app:process_real_app ?file ?loc st
        solver defn
  | _ -> Loop.State.error ?file ?loc st unsupported_statement "non-real term"

and process_bool_const ?file ?loc st _solver (_cst : Term.Const.t) =
  Loop.State.error ?file ?loc st unsupported_statement "boolean constant"

and process_bool_app ?file ?loc st solver (fn : Term.Const.t) xs =
  match (fn.builtin, xs) with
  | B.And, _ ->
      List.fold_left
        (fun st x -> process_bool_term ?file ?loc st solver x)
        st xs
  | B.Equal, [ x; y ] ->
      let x_term = process_real_term ?file ?loc st solver x in
      let y_term = process_real_term ?file ?loc st solver y in
      Nra_solver.assert_eq solver x_term y_term;
      st
  | B.Distinct, [ x; y ] ->
      let x_term = process_real_term ?file ?loc st solver x in
      let y_term = process_real_term ?file ?loc st solver y in
      Nra_solver.assert_neq solver x_term y_term;
      st
  | B.Lt `Real, [ x; y ] ->
      let x_term = process_real_term ?file ?loc st solver x in
      let y_term = process_real_term ?file ?loc st solver y in
      Nra_solver.assert_lt solver x_term y_term;
      st
  | B.Leq `Real, [ x; y ] ->
      let x_term = process_real_term ?file ?loc st solver x in
      let y_term = process_real_term ?file ?loc st solver y in
      Nra_solver.assert_leq solver x_term y_term;
      st
  | B.Gt `Real, [ x; y ] ->
      let x_term = process_real_term ?file ?loc st solver x in
      let y_term = process_real_term ?file ?loc st solver y in
      Nra_solver.assert_gt solver x_term y_term;
      st
  | B.Geq `Real, [ x; y ] ->
      let x_term = process_real_term ?file ?loc st solver x in
      let y_term = process_real_term ?file ?loc st solver y in
      Nra_solver.assert_geq solver x_term y_term;
      st
  | _ ->
      Loop.State.error ?file ?loc st unsupported_statement
        "unknown or unsupported boolean operator/arity"

and process_real_const ?file ?loc st _solver (cst : Term.Const.t) =
  match cst.builtin with
  | B.Base -> (
      match Term.Const.get_tag cst var_tag with
      | None ->
          Loop.State.error ?file ?loc st unsupported_statement
            "unknown or untagged real constant"
      | Some var -> Nra_solver.Term.variable var)
  | B.Decimal dec -> Nra_solver.Term.real dec
  | _ ->
      Loop.State.error ?file ?loc st unsupported_statement
        "unknown or unsupported real constant type"

and process_real_app ?file ?loc st solver (fn : Term.Const.t) xs =
  match (fn.builtin, xs) with
  | B.Minus `Real, [ x ] ->
      let x_term = process_real_term ?file ?loc st solver x in
      Nra_solver.Term.minus x_term
  | B.Add `Real, [ x; y ] ->
      let x_term = process_real_term ?file ?loc st solver x in
      let y_term = process_real_term ?file ?loc st solver y in
      Nra_solver.Term.add x_term y_term
  | B.Sub `Real, [ x; y ] ->
      let x_term = process_real_term ?file ?loc st solver x in
      let y_term = process_real_term ?file ?loc st solver y in
      Nra_solver.Term.sub x_term y_term
  | B.Mul `Real, [ x; y ] ->
      let x_term = process_real_term ?file ?loc st solver x in
      let y_term = process_real_term ?file ?loc st solver y in
      Nra_solver.Term.mul x_term y_term
  | B.Div `Real, [ x; y ] ->
      let x_term = process_real_term ?file ?loc st solver x in
      let y_term = process_real_term ?file ?loc st solver y in
      Nra_solver.Term.div x_term y_term
  | _ ->
      Loop.State.error ?file ?loc st unsupported_statement
        "unknown or unsupported real operator/arity"

let process_term_def ?file ?loc st solver cst (defn : Term.t) =
  match Ty.view (Term.Const.ty cst) with
  | `Real ->
      let name = Fmt.to_to_string Term.Const.print cst in
      let var = Nra_solver.create_variable solver name in
      Term.Const.set_tag cst var_tag var;
      let defn_term = process_real_term ?file ?loc st solver defn in
      Nra_solver.assert_eq solver (Nra_solver.Term.variable var) defn_term;
      st
  | _ ->
      Loop.State.error ?file ?loc st unsupported_statement
        "definition of non-real constant"

let process_defs ?file ?loc st solver (defs : Loop.Typer_Pipe.def list) =
  (* Filter out type definitions (inlined by Dolmen) and instance checks,
     which are only used in models when completing a polymorphic
     partially-defined builtin. *)
  let defs =
    List.filter_map
      (function
        | `Type_alias _ | `Instanceof _ -> None | `Term_def _ as def -> Some def)
      defs
  in
  match defs with
  | [] -> st
  | [ `Term_def (_id, cst, [], [], defn) ] ->
      process_term_def ?file ?loc st solver cst defn
  | [ `Term_def (_id, _cst, (_ :: _ as _tyvs), [], _defn) ] ->
      Loop.State.error ?file ?loc st unsupported_statement
        "definition of polymorphic constant"
  | [ `Term_def (_id, _cst, _tyvs, (_ :: _ as _xs), _defn) ] ->
      Loop.State.error ?file ?loc st unsupported_statement "function definition"
  | _ :: _ :: _ ->
      Loop.State.error ?file ?loc st unsupported_statement
        "mutually recursive definition"

let process_term_decl ?file ?loc st solver cst =
  match Ty.view (Term.Const.ty cst) with
  | `Real ->
      let name = Fmt.to_to_string Term.Const.print cst in
      let var = Nra_solver.create_variable solver name in
      Term.Const.set_tag cst var_tag var;
      st
  | _ ->
      Loop.State.error ?file ?loc st unsupported_statement
        "declaration of non-real constant"

let process_decls ?file ?loc st solver (decls : Loop.Typer_Pipe.decl list) =
  match decls with
  | [] -> st
  | [ `Type_decl _ ] ->
      Loop.State.error ?file ?loc st unsupported_statement "type declaration"
  | [ `Term_decl cst ] -> process_term_decl ?file ?loc st solver cst
  | _ :: _ :: _ ->
      Loop.State.error ?file ?loc st unsupported_statement
        "mutually recursive declaration"

let process_hyp ?file ?loc st solver hyp =
  match Ty.view (Term.ty hyp) with
  | `Prop -> process_bool_term ?file ?loc st solver hyp
  | _ -> Loop.State.error ?file ?loc st unsupported_statement "non-prop hyp"

let process_stmts st solver stmts =
  List.fold_left
    (fun st (stmt : Loop.Typer_Pipe.typechecked Loop.Typer_Pipe.stmt) ->
      let file = Loop.State.get Loop.State.logic_file st in
      let loc : Loc.full = { file = file.loc; loc = stmt.loc } in
      match stmt.contents with
      | `Defs defs -> process_defs ~file ~loc st solver defs
      | `Decls decls -> process_decls ~file ~loc st solver decls
      | `Hyp hyp -> process_hyp ~file ~loc st solver hyp
      | `Goal _goal ->
          Loop.State.error ~file ~loc st unsupported_statement "goal"
      | `Clause _clause ->
          Loop.State.error ~file ~loc st unsupported_statement "clause"
      | `Solve ([], []) ->
          let result = Nra_solver.solve solver in
          Fmt.pr "%s@."
            (match result with
            | Sat -> "sat"
            | Unsat -> "unsat"
            | Unknown -> "unknown");
          st
      | `Solve (_hyps, _goals) ->
          Loop.State.error ~file ~loc st unsupported_statement
            "local hypotheses or conclusions in (check-sat-assuming)"
      | `Set_logic _logic ->
          (* Ignore (set-logic). *)
          st
      | #Loop.Typer_Pipe.get_info | #Loop.Typer_Pipe.set_info ->
          Fmt.pr "(error \"info commands not supported\")@.";
          st
      | #Loop.Typer_Pipe.stack_control ->
          Loop.State.error ~file ~loc st unsupported_statement
            "stack control commands (push/pop/reset)"
      | `Exit ->
          (* Dolmen will stop on its own here. *)
          st)
    st stmts

let run st logic_file =
  let g = Loop.Parser.parse_logic logic_file in
  let open Loop.Pipeline in
  let finally st err =
    match err with None -> st | Some (_bt, _exn) -> exit 125
  in
  let solver = Loop.State.get nra_solver_key st in
  let st =
    run ~finally g st
      (fix
         (op ~name:"expand" Loop.Parser.expand)
         (op ~name:"flow" Loop.Flow.inspect
         @>>> op ~name:"typecheck" Loop.Typer_Pipe.typecheck
         @>|> op (fun st stmts -> (process_stmts st solver stmts, ()))
         @>>> _end))
  in
  ignore (Loop.State.flush st ())

open Cmdliner
open Cmdliner.Term.Syntax

let mode_enum = [ ("full", `Full); ("incremental", `Incremental) ]

let input_source_conv =
  let parse = function "-" -> Ok `Stdin | f -> Ok (`File f) in
  let print ppf = function
    | `Stdin -> Fmt.string ppf "-"
    | `File f -> Fmt.string ppf f
  in
  Arg.conv (parse, print)

let logic_file =
  let+ lang =
    let doc =
      Fmt.str "Set the input language. $(docv) must be %s."
        (Arg.doc_alts_enum ~quoted:true Dolmen_loop.Logic.enum)
    in
    Arg.(
      value
      & opt (some (Arg.enum Dolmen_loop.Logic.enum)) None
      & info [ "lang" ] ~docv:"LANG" ~doc)
  and+ mode =
    let doc =
      Fmt.str "Set the input mode. $(docv) must be %s."
        (Arg.doc_alts_enum ~quoted:true mode_enum)
    in
    Arg.(
      value
      & opt (some (Arg.enum mode_enum)) None
      & info [ "m"; "mode" ] ~docv:"MODE" ~doc)
  and+ fname =
    let doc = Fmt.str "Input problem file." in
    Arg.(value & pos 0 input_source_conv `Stdin & info [] ~docv:"FILE" ~doc)
  in
  let dir, source = Loop.State.split_input fname in
  Loop.State.mk_file ?lang ?mode dir source

let state =
  Term.const
    (Loop.State.empty
    |> Loop.State.init ~debug:false ~report_style:Contextual ~max_warn:max_int
         ~reports:(Dolmen_loop.Report.Conf.mk ~default:Enabled)
         ~response_file:(Loop.State.mk_file "<unused>" `Stdin)
         ~time_limit:0. ~size_limit:0.
    |> Loop.Parser.init |> Loop.Typer.init
    |> Loop.Typer_Pipe.init ~type_check:true
    |> Loop.Flow.init ~flow_check:true
    |> Loop.State.set nra_solver_key (Nra_solver.create ()))

let run_cmd =
  Cmd.v (Cmd.info "nra_solver" ~version:"%%VERSION%%")
  @@
  let+ st = state and+ logic_file = logic_file in
  run st logic_file

let main () = Cmd.eval run_cmd
let () = if not !Sys.interactive then exit (main ())
