(* Copyright (C) 1999-2002 Henry Cejtin, Matthew Fluet, Suresh
 *    Jagannathan, and Stephen Weeks.
 * Copyright (C) 1997-1999 NEC Research Institute.
 *
 * MLton is released under the GNU General Public License (GPL).
 * Please see the file MLton-LICENSE for license information.
 *)
functor ImplementHandlers (S: IMPLEMENT_HANDLERS_STRUCTS): IMPLEMENT_HANDLERS = 
struct

open S
open Rssa
datatype z = datatype Statement.t
datatype z = datatype Transfer.t

structure LabelInfo =
   struct
      type t = {block: Block.t,
		handlerStack: Label.t list option ref,
		replacement: Statement.t vector option ref,
		visited: bool ref}

      fun layout ({handlerStack, visited, ...}: t) =
	 Layout.record
	 [("handlerStack",
	   Option.layout (List.layout Label.layout) (!handlerStack)),
	  ("visited", Bool.layout (!visited))]
   end

structure Function =
   struct
      open Function

      fun hasHandler (f: t): bool =
	 let
	    val {blocks, ...} = dest f
	 in
	    Vector.exists
	    (blocks, fn Block.T {transfer, ...} =>
	     case transfer of
		Transfer.Call
		{return = (Return.NonTail
			   {handler = Handler.Handle _, ...}), ...} =>
		   true
              | _ => false)
	 end
   end

structure HandlerLat = FlatLattice (structure Point = Label)

structure ExnStack =
   struct
      local
	 structure ZPoint =
	    struct
	       datatype t = Local | Slot
	       
	       val equals: t * t -> bool = op =
	       
	       val toString =
		  fn Local => "Local"
		   | Slot => "Slot"

	       val layout = Layout.str o toString
	    end
	 structure L = FlatLattice (structure Point = ZPoint)
      in
	 open L
	 structure Point = ZPoint
	 val locall = point Point.Local
	 val slot = point Point.Slot
      end
   end

fun flow (f: Function.t): Function.t =
   if not (Function.hasHandler f)
      then f
   else
   let
      val debug = false
      val {args, blocks, name, raises, returns, start} =
	 Function.dest f
      val {get = labelInfo: Label.t -> {global: ExnStack.t,
					handler: HandlerLat.t}, ...} =
	 Property.get (Label.plist,
		       Property.initFun (fn _ =>
					 {global = ExnStack.new (),
					  handler = HandlerLat.new ()}))
      val _ =
	 Vector.foreach
	 (blocks, fn Block.T {label, transfer, ...} =>
	  let
	     val {global, handler} = labelInfo label
	     val _ =
		if Label.equals (label, start)
		   then (ExnStack.<= (ExnStack.slot, global)
			 ; HandlerLat.forceTop handler
			 ; ())
		else ()
	     fun goto' {global = g, handler = h}: unit =
		(ExnStack.<= (global, g)
		 ; HandlerLat.<= (handler, h)
		 ; ())
	     val goto = goto' o labelInfo
	  in
	     case transfer of
		Call {return, ...} =>
		   (case return of
		       Return.Dead => ()
		     | Return.NonTail {cont, handler = h} =>
			  let
			     val li as {global = g', handler = h'} =
				labelInfo cont
			  in
			     case h of
				Handler.Caller =>
				   (ExnStack.<= (ExnStack.slot, g')
				    ; HandlerLat.<= (handler, h')
				    ; ())
			      | Handler.Dead => goto' li
			      | Handler.Handle l =>
				   let
				      fun doit {global = g'', handler = h''} =
					 (ExnStack.<= (ExnStack.locall, g'')
					  ; (HandlerLat.<=
					     (HandlerLat.point l, h'')))
				   in
				      doit (labelInfo l)
				      ; doit li
				      ; ()
				   end
			  end
		     | Return.Tail => ())
	      | _ => Transfer.foreachLabel (transfer, goto)
	  end)
      val _ =
	 if debug
	    then
	       Layout.outputl
	       (Vector.layout
		(fn Block.T {label, ...} =>
		 let
		    val {global, handler} = labelInfo label
		 in
		    Layout.record [("label", Label.layout label),
				   ("global", ExnStack.layout global),
				   ("handler", HandlerLat.layout handler)]
		 end)
		blocks,
		Out.error)
	 else ()
      val blocks =
	 Vector.map
	 (blocks,
	  fn Block.T {args, kind, label, statements, transfer} =>
	  let
	     val {global, handler} = labelInfo label
	     fun setExnStackSlot () =
		if ExnStack.isPointEq (global, ExnStack.Point.Slot)
		   then Vector.new0 ()
		else Vector.new1 SetExnStackSlot
	     fun setExnStackLocal () =
		if ExnStack.isPointEq (global, ExnStack.Point.Local)
		   then Vector.new0 ()
		else Vector.new1 SetExnStackLocal
	     fun setHandler (l: Label.t) =
		if HandlerLat.isPointEq (handler, l)
		   then Vector.new0 ()
		else Vector.new1 (SetHandler l)
	     val post =
		case transfer of
		   Call {args, func, return} =>
		      (case return of
			  Return.Dead => Vector.new0 ()
			| Return.NonTail {cont, handler} =>
			     (case handler of
				 Handler.Caller => setExnStackSlot ()
			       | Handler.Dead => Vector.new0 ()
			       | Handler.Handle l =>
				    Vector.concat
				    [setHandler l, setExnStackLocal ()])
			| Return.Tail => setExnStackSlot ())
		 | Raise _ => setExnStackSlot ()
		 | Return _ => setExnStackSlot ()
		 | _ => Vector.new0 ()
	     val statements = Vector.concat [statements, post]
	  in
	     Block.T {args = args,
		      kind = kind,
		      label = label,
		      statements = statements,
		      transfer = transfer}
	  end)
      val newStart = Label.newNoname ()
      val startBlock =
	 Block.T {args = Vector.new0 (),
		  kind = Kind.Jump,
		  label = newStart,
		  statements = Vector.new1 SetSlotExnStack,
		  transfer = Goto {args = Vector.new0 (),
				   dst = start}}
      val blocks = Vector.concat [blocks, Vector.new1 startBlock]
   in
      Function.new {args = args,
		    blocks = blocks,
		    name = name,
		    raises = raises,
		    returns = returns,
		    start = newStart}
   end

fun pushPop (f: Function.t): Function.t =
   let
      val {args, blocks, name, raises, returns, start} =
	 Function.dest f
      val {get = labelInfo: Label.t -> LabelInfo.t,
	   set = setLabelInfo, ...} =
	 Property.getSetOnce
	 (Label.plist, Property.initRaise ("info", Label.layout))
      val _ =
	 Vector.foreach
	 (blocks, fn b as Block.T {label, ...} =>
	  setLabelInfo (label,
			{block = b,
			 handlerStack = ref NONE,
			 replacement = ref NONE,
			 visited = ref false}))
      (* Do a dfs from the start, figuring out the handler stack at
       * each label.
       *)
      fun visit (l: Label.t, hs: Label.t list): unit =
	 let
	    val {block, handlerStack, replacement, visited} = labelInfo l
	    val Block.T {statements, transfer, ...} = block
	 in
	    if !visited
	       then ()
	    else
	       let
		  val _ = visited := true
		  fun bug msg =
		     (Vector.layout
		      (fn Block.T {label, ...} =>
		       let open Layout
		       in seq [Label.layout label,
			       str " ",
			       LabelInfo.layout (labelInfo label)]
		       end)
		      ; Error.bug (concat
				   [msg, ": ", Label.toString l]))
		  val _ =
		     case !handlerStack of
			NONE => handlerStack := SOME hs
		      | SOME hs' =>
			   if List.equals (hs, hs', Label.equals)
			      then ()
			   else bug "handler stack mismatch"
		  val hs =
		     if not (Vector.exists
			     (statements, fn s =>
			      case s of
				 HandlerPop _ => true
			       | HandlerPush _ => true
			       | _ => false))
			(* An optimization to avoid recopying blocks
			 * with no handlers.
			 *)
			then (replacement := SOME statements
			      ; hs)
		     else
			let
			   val (hs, ac) =
			      Vector.fold
			      (statements, (hs, []), fn (s, (hs, ac)) =>
			       case s of
				  HandlerPop _ =>
				     (case hs of
					 [] => bug "pop of empty handler stack"
				       | _ :: hs =>
					    let
					       val s =
						  case hs of
						     [] => SetExnStackSlot
						   | h :: _ => SetHandler h
					    in (hs, s :: ac)
					    end)
				| HandlerPush h =>
				     let
					val ac = SetHandler h :: ac
					val ac =
					   case hs of
					      [] =>
						 SetExnStackLocal
						 :: SetSlotExnStack
						 :: ac
					    | _ => ac
				     in
					(h :: hs, ac)
				     end
				| _ => (hs, s :: ac))
			   val _ =
			      replacement := SOME (Vector.fromListRev ac)
			in
			   hs
			end
	       in
		  Transfer.foreachLabel (transfer, fn l =>
					 visit (l, hs))
	       end
	 end
      val _ = visit (start, [])
      val blocks =
	 Vector.map
	 (blocks, fn b as Block.T {args, kind, label, transfer, ...} =>
	  let
	     val {replacement, visited, ...} = labelInfo label
	  in
	     if !visited
		then Block.T {args = args,
			      kind = kind,
			      label = label,
			      statements = valOf (! replacement),
			      transfer = transfer}
	     else b
	  end)
   in
      Function.new {args = args,
		    blocks = blocks,
		    name = name,
		    raises = raises,
		    returns = returns,
		    start = start}
   end

fun simple (f: Function.t): Function.t =
   if not (Function.hasHandler f)
      then f
   else
   let
      val {args, blocks, name, raises, returns, start} =
	 Function.dest f
      val blocks =
	 Vector.map
	 (blocks,
	  fn Block.T {args, kind, label, statements, transfer} =>
	  let
	     val post =
		case transfer of
		   Call {args, func, return} =>
		      (case return of
			  Return.Dead => Vector.new0 ()
			| Return.NonTail {cont, handler} =>
			     (case handler of
				 Handler.Caller =>
				    Vector.new1 SetExnStackSlot
			       | Handler.Dead => Vector.new0 ()
			       | Handler.Handle l =>
				    Vector.new2 (SetHandler l,
						 SetExnStackLocal))
			| Return.Tail =>
			     Vector.new1 SetExnStackSlot)
		 | Raise _ => Vector.new1 SetExnStackSlot
		 | Return _ => Vector.new1 SetExnStackSlot
		 | _ => Vector.new0 ()
	     val statements = Vector.concat [statements, post]
	  in
	     Block.T {args = args,
		      kind = kind,
		      label = label,
		      statements = statements,
		      transfer = transfer}
	  end)
      val newStart = Label.newNoname ()
      val startBlock =
	 Block.T {args = Vector.new0 (),
		  kind = Kind.Jump,
		  label = newStart,
		  statements = Vector.new1 SetSlotExnStack,
		  transfer = Goto {args = Vector.new0 (),
				   dst = start}}
      val blocks = Vector.concat [blocks, Vector.new1 startBlock]
   in
      Function.new {args = args,
		    blocks = blocks,
		    name = name,
		    raises = raises,
		    returns = returns,
		    start = newStart}
   end

fun doit (Program.T {functions, main, objectTypes}) =
   let
      val implementFunction =
	 case !Control.handlers of
	    Control.Flow => flow
	  | Control.PushPop => pushPop
	  | Control.Simple => simple
   in
      Program.T {functions = List.revMap (functions, implementFunction),
		 main = main,
		 objectTypes = objectTypes}
   end

end
