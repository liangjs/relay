(*
  Copyright (c) 2006-2007, Regents of the University of California

  Authors: Jan Voung
  
  All rights reserved.
  
  Redistribution and use in source and binary forms, with or without 
  modification, are permitted provided that the following 
  conditions are met:
  
  1. Redistributions of source code must retain the above copyright 
  notice, this list of conditions and the following disclaimer.

  2. Redistributions in binary form must reproduce the above 
  copyright notice, this list of conditions and the following disclaimer 
  in the documentation and/or other materials provided with the distribution.

  3. Neither the name of the University of California, San Diego, nor 
  the names of its contributors may be used to endorse or promote 
  products derived from this software without specific prior 
  written permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
  PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
  LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
  NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  
*)

(** The intra-procedural portion of the dataflow analysis for 
    finding data races *)

open Callg
open Cil
open Pretty
open Fstructs
open Scc_cg
open Messages
open Cilinfos
open Manage_sums
open Lockset

module Par = Pseudo_access
module LP = Lockset_partitioner

module AD = Analysis_dep
module IH = Inthash
module DF = Dataflow
module IDF = InterDataflow
module Intra = IntraDataflow
module A = Alias
module Sh = Shared
module RS = Racesummary
module Du = Cildump
module BS = Backed_summary
module Stat = Mystats
module L = Logging

module CLv = Cil_lvals
module Lv = Lvals

module SPTA = Racestate.SPTA

module I = Inspect


(***************************************************)
(* Intra-proc Analysis                             *)

let debug = false
let inspect = ref false

let setInspect yesno =
  Racestate.setInspect yesno;
  inspect := yesno


module RaceDF = Racestate.RaceDF
module FITransF = Racestate.FITransF
module RaceForwardDF = Racestate.RaceForwardDF
let getLocksBefore = Racestate.getLocksBefore


(***************************************************)
(* Inter-proc Analysis                             *)
  
  
(** Info needed by the inter-proc driver *)
module RaceBUTransfer = struct
  

  (**** Statistics kept ****)
  
  let sccsDone = ref 0

  let sccsTotal = ref 0

  let curCG = ref FMap.empty

  let curSCCCG = ref IntMap.empty

  let initStats (cg:simpleCallG) (sccCG: sccGraph) (finalFuncs:fKey list) : unit = 
    (curCG := cg;
     curSCCCG := sccCG;
     (* TODO: clean this up... *)
     Intra.curCG := cg;
     Intra.curSCCCG := sccCG;

     (* Progress *)
     sccsTotal := Stdutil.mapSize sccCG IntMap.fold;
     sccsDone := 0;
    )

      
  let updateStats (lastSCC:scc) = 
    (* Progress *)
    incr sccsDone;
    L.logStatus (">>> PROGRESS " ^ (string_of_int !sccsDone) ^ "/" ^
                    (string_of_int !sccsTotal) ^ " SCCs DONE!\n")


  (**** State management / calculation ****)

  type state = RS.state

  let seedRS cfg fkey =
    (* Seed the guarded access pass w/ the summary from previous pass *)
    let curSummary = RS.sum#find fkey in
    let curSumOut = RS.summOutstate curSummary in
    let curGAs = curSumOut.RS.cState in
    FITransF.initState cfg curGAs;


  (**** List of analyses that should be run (listed in order) *****)

  class ['st] writeOnlyAnalyzer = object (self)
    inherit ['st] Racestate.readWriteAnalyzer

    (** override addRefs to leave out the reads *)
    method addRefs curLS st loc exp =
      st

  end

  class raceAnalysis rwChecker = object (self)
    inherit Racestate.raceAnalysis rwChecker

    (** Override compute to seed state first *)
    method compute cfg =
      (* TODO: get rid of input *)
      let input = RS.emptyState in
      RaceDF.initState cfg input.RS.lState;
      let fk = funToKey cfg in      
      seedRS cfg fk;
      Stat.time "Race/Lockset DF: " 
        (fun () ->
           (* Compute locksets *)
           L.logStatus "doing lockset";
           L.flushStatus ();
           RaceForwardDF.compute cfg.sallstmts;
         
           (* Update read/write correlation info *)
           L.logStatus "doing guarded access";
           L.flushStatus ();
           let gaVisitor = new FITransF.guardedAccessSearcher 
             rwChecker getLocksBefore in
           ignore (visitCilFunction (gaVisitor :> cilVisitor) cfg);
        ) ()

  end

  let ssAna = new SPTA.symexAnalysis
  let rsAna = new raceAnalysis (new writeOnlyAnalyzer)

  let needsFixpoint : AD.analysis list = 
    [ ssAna; rsAna ]

  let nonFixpoint : AD.analysis list = []

  let flushSummaries () =
    RS.sum#serializeAndFlush;
    SPTA.SS.sum#serializeAndFlush;
(*    Par.sums#serializeAndFlush; *)
    LP.sums#evictSummaries
        
  let doFunc ?(input:state = RS.emptyState) (fk: fKey) (f:simpleCallN) 
      : state IDF.interResult =
    let fn, defFile = f.name, f.defFile in
    L.logStatus ("Summarizing function: " ^ fn ^ " : " ^ defFile);
    L.logStatus "-----";
    L.flushStatus ();
    match Intra.getFunc fk f with
      Some cfg ->
        if Intra.runFixpoint needsFixpoint cfg then
          IDF.NewOutput (input, input) (* TODO: change return type *)
        else
          IDF.NoChange
          
    | None ->
        (* Don't have function definition *)
        L.logError ("doFunc can't get CFG for: " ^ 
                      (string_of_fNT (fn, defFile)));
        IDF.NoChange 


  (** TRUE if the function should be put on the worklist *)
  let filterFunc f : bool =
    true

  (* TODO: make this not use all of the summary types, just the ones needed *)
  let hardCodedSumTypes ()  =
    BS.getDescriptors [RS.sum#sumTyp;
                       SPTA.SS.sum#sumTyp;
                       Par.sums#sumTyp;
                       LP.sums#sumTyp]

  (** Prepare to start an scc, acquiring the required summaries *)
  let sccStart (scc:scc)  = begin
    (* Get all summaries for all callees *)
    let callees = IntSet.fold
      (fun neighSCCID curList ->
         let neighSCC = IntMap.find neighSCCID !curSCCCG in
         FSet.fold
           (fun f curList ->
              f :: curList
           ) neighSCC.scc_nodes curList
      ) scc.scc_callees [] in
    L.logStatus "Acquiring needed summaries";
    L.flushStatus ();
    prepareSumms callees (hardCodedSumTypes ());

    L.logStatus "Acquiring RS/SS summaries for current SCC";
    let ownFuns = FSet.elements scc.scc_nodes in
    prepareSumms ownFuns (BS.getDescriptors [RS.sum#sumTyp;
                                             SPTA.SS.sum#sumTyp;
                                             Par.sums#sumTyp;
                                             LP.sums#sumTyp]);
  end

  (** Scc is summarized. Do the rest *) 
  let sccDone (scc:scc) (byThisGuy:bool) =
    let summPaths = if (byThisGuy) then
      (try
         (* Now that all locksets have been computed, do the remaining passes *)
         let prevFunc = !Racestate.curFunc in
         let prevFKey = funToKey prevFunc in
         Intra.runNonFixpoint nonFixpoint needsFixpoint prevFKey scc;

         (* Debugging *)
         FSet.iter 
           (fun fkey -> ();
              (*L.logStatus ("Summary for function: " ^ 
                              (string_of_fkey fkey));
              L.logStatus "=======\n";
              RS.printSummary fkey;
              SPTA.SS.printSummary fkey;*)
           ) scc.scc_nodes;

         (* Serialize and record where each fun was placed *)
         flushSummaries ();

         (* Find out where the summaries were stored *)
         (* TODO: force them to pick the same directory 
            (which they do unless one partition runs out of space) *)
         let tokenMap = RS.sum#locate (FSet.elements scc.scc_nodes) in
         
         (* Notify others that the functions are now summarized *)
         List.fold_left
           (fun paths (fkey, tok) ->
              let path = BS.pathFromToken tok in
              (fkey, path) :: paths
           ) [] tokenMap
       with e ->
         L.logError ("Caught exception in sccDone?" ^ 
                         (Printexc.to_string e));
         raise e
      ) else [] in
    updateStats scc; (* and possibly delete obsolete summaries *)
    summPaths
    (* RFC.clear !astFCache *)

end

module BUDataflow = IDF.BottomUpDataflow (RaceBUTransfer)