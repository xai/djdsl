# -*- Tcl -*-
#
# MIT License
#
# Copyright (c) 2017, 2018 Stefan Sobernig <stefan.sobernig@wu.ac.at>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

package req Tcl 8.6

apply {{version prj code {test ""}} {
  set script [file normalize [info script]]
  set modver [file root [file tail $script]]
  lassign [split $modver -] ns relVersion
  # set prj [file tail [file dirname $script]]
  
  if {$relVersion ne ""} {
    set version $relVersion
  }

  # package provide ${prj}::$ns $version
  # namespace eval ${prj}::$ns $code

  if {[info exists ::argv0] && $::argv0 eq [uplevel 1 {info script}]} {
    if {"--release" in $::argv} {
      try {
        file copy -force -- $script ${ns}-${version}.tm
      } on error {e} {
        puts stderr "Failed to create release file: '$e'"
      } finally {
        set ::argv [lsearch -exact -inline -all -not $::argv "--release"]
      }
    } elseif {"--print" in $::argv} {
      try {
        if {$test ne ""} {
          puts stdout [string trim [regsub -line -all {^[ \t][ \t]} $test ""]]
        }
        puts stdout [string trim [regsub -line -all {^[ \t][ \t]} $code ""]]
      } finally {
        set ::argv [lsearch -exact -inline -all -not $::argv "--print"]
      }
    } else {
      if {$test ne ""} {
        package req tcltest
        ::tcltest::configure {*}$::argv
        ::tcltest::loadTestedCommands
        
        uplevel #0 [list namespace eval ${prj}::$ns $code]
        namespace eval ::${prj}::${ns}::test {
          namespace import ::tcltest::*

          customMatch stripNs [list apply {{testNs expected actual} {
            set strippedActual [string map [list ${testNs} ""] $actual]
            expr {$strippedActual eq $expected}
          }} [namespace current]]

          
          ::proc ? {script expected} {
            set ctr [incr [namespace current]::counter]
            uplevel [list test test-$ctr "" -body $script -match stripNs -result $expected \
                         -returnCodes {0 1 2}]
          }          
        }
        
        namespace eval ::${prj}::${ns}::test [list namespace import ::${prj}::${ns}::*]
        uplevel #0 [list namespace eval ::${prj}::${ns}::test $test]
        
        namespace eval ::${prj}::${ns}::test cleanupTests
        namespace delete ::${prj}::${ns}::test
      }
    }
  } else {
    package provide ${prj}::$ns $version
    namespace eval ${prj}::$ns $code
  }
} ::} 0.1 djdsl {

  #
  # == Implementation
  #
  
  package req djdsl::lm
  namespace import ::djdsl::lm::*


  nx::Object create callContext {
    set :frames [list]

    :require namespace
    namespace eval [self] {
      namespace path {}
    }
    
    :public object method set {next element validators} {

      set newFrame [list $next $element $validators 0]
      set :frames [linsert ${:frames}[set :frames {}] 0 $newFrame]
      
    }
    :public object method clear {} {
      set :frames [lassign ${:frames} currentFrame]
      return [lindex $currentFrame end]
      
    }
    :public object method original args {
      # peek current frame
      set currentFrame [lindex ${:frames} 0]
      lassign $currentFrame next element validators counter
      
      incr counter
      # puts stderr "EXPLICIT($counter) $next validate $element $validators"
      try {
        if {${next} ne ""} {
          ${next} validate ${element} ${validators}
        }
        return 1
      } trap {DJDSL CTX VIOLATED} {e opts} {
        return 0
      } on error {e opts} {
        return -options $opts $e
      } finally {
        lset currentFrame 3 $counter
        lset :frames 0 $currentFrame
      }
    }
    interp alias {} [self]::next {} [self] original
  }

  nx::Class create Condition {
    :property label
    :property -accessor public bodyExpression:required
    :property {expressionType "tcl"}
    :property context:object,type=AssetElement
  }
  
  AssetElement property \
      -accessor public \
      -incremental \
      condition:0..*,object,type=[namespace current]::Condition
  
  AssetElement protected method compileScript {} {
    set f ""

    # add "basic" constraints
    set varSlots [:info variables]
    foreach vs $varSlots {
      set spec [$vs parameter]
      set options [::nx::MetaSlot parseParameterSpec {*}$spec]
      set name [lindex $options 0]
      set options [lindex $options end]

      if {[llength $spec] == 2} {
        set exprStr "\[info exists :$name\]"
        set thenScript [list return -level 0 -code error \
                            -errorcode [list DJDSL CTX VIOLATED $vs] \
                            "condition '$exprStr' failed"]
        append f [list if !($exprStr) $thenScript] \;
      }
      
      # Add checks for multi-valuedness == list
      
      if {[$vs eval {:isMultivalued}]} {
        set exprStr "\[::string is list \${:$name}\]"
        set thenScript [list return -level 0 -code error \
                            -errorcode [list DJDSL CTX VIOLATED $vs] \
                            "condition '$exprStr' failed"]
        append f [list if !($exprStr) $thenScript] \;
      }
      
      if {$options ne ""} {
        set nspec [::nx::MetaSlot optionsToValueCheckingSpec $options]
        set exprStr "!\[info exists :$name\] || \[::nsf::is $nspec \${:$name}\]"
        # set exprStr "\[::nsf::is $nspec \${:$name}\]"
        set thenScript [list return -level 0 -code error \
                            -errorcode [list DJDSL CTX VIOLATED $vs] \
                            "condition '$exprStr' failed"]
        append f [list if !($exprStr) $thenScript] \;
      }
      
      # TODO: provided that type is of type "AssetElement", check
      # also there constraints?

    }

    if {[info exists :condition] && [llength ${:condition}]} {
      foreach c ${:condition} {
        set exprStr [$c bodyExpression get]
        set thenScript [list return -level 0 -code error \
                            -errorcode [list DJDSL CTX VIOLATED $c] \
                            "condition '$exprStr' failed"]
        append f [list if !($exprStr) $thenScript] \;
      }
    }
    
    if {$f ne "" && ![info complete $f]} {
      throw [list DJDSL CTX FAILED SCRIPT [self] $f] "Validation script is not complete."
    }
    
    return $f
  }

  AssetElement public method validate {-or:switch args} {
    if {$or} {
      :validate2 inplace -or=$or {*}$args
    } else {
      :validate2 inplace -and {*}$args
    }
  }

  AssetElement public method "validate2 outplace" {
                                                   -or:switch
                                                   -and:switch
                                                   e:object
                                                   validators:optional
                                                 } {
    package req nx::serializer
    set dummy [namespace current]::_
    set s [Serializer deepSerialize -map [list $e $dummy] $e]
    try {
      try $s
      :validate2 inplace -or=$or -and=$and $dummy \
          {*}[expr {[info exists validators]?[list $validators]:""}]
    } finally {
      catch {$dummy destroy}
    }
  }
  
  AssetElement public method "validate2 inplace" {
                                                  -or:switch
                                                  -and:switch
                                                  e:object
                                                  validators:optional
                                                } {

    if {$or && $and} {
      throw [list DJDSL CTX FAILED CHAINING [self]] \
          "OR and AND chaining are mutually exclusive."
    }

    set atHead 0
    
    if {![info exists validators]} {
      set atHead 1
      set ancestors [$e info precedence]
      if {[self] ni $ancestors} {
        throw [list DJDSL CTX FAILED ANCESTRY [self] $e] \
            "Not allowed: '[self]' is not in the refinement chain '$ancestors'"
      }
      # Skip forward to [self] as first validator, plus 1
      set helpers [list]
      set validators [list]
      set seenSelf 0
      foreach ancestor $ancestors {
        if {$ancestor eq [self]} {
          set seenSelf 1
        }

        if {!$seenSelf} {continue;}

        if {[$ancestor eval {info exists :helpers}]} {
          lappend helpers [$ancestor helpers get]
        }
        
        if {$ancestor ne [self] && [$ancestor info has type [current class]]} {
          # puts "lappend validators $ancestor"
          lappend validators $ancestor
        }
      }
      set validators2 [lrange $ancestors [expr {[lsearch -exact $ancestors [self]]+1}] end]
      #puts $validators2==$validators
      # unset seenSelf
      if {[llength $helpers]} {
        $e object mixins set $helpers
      }
    }
    
    set explicitNexts 0
    set validators [lassign $validators next]
    ## TODO: better way to capture validators without conditions

    set f [:compileScript]
    # set hasConditions [expr {[info exists :condition] && [llength ${:condition}]}]
    # puts stderr "---$hasConditions && !$or && !$and"
    if {$next ne ""} {
      if {![$next info has type [current class]]} {
        set next ""
      }
      if {$f ne "" && !$or && !$and} {
        set next ""
      }
    }

    # puts next='$next',f=$f
    if {$f ne ""} {
      try {
        # puts stderr "([self]) ::djdsl::ctx::context set $next $e $validators"
        ::djdsl::ctx::callContext set $next $e $validators
        # puts stderr "[list apply [list {} $f ::djdsl::ctx::context]]"
        $e eval [list apply [list {} $f ::djdsl::ctx::callContext]]
      } trap {DJDSL CTX VIOLATED} {errMsg opts} {
        # propagate violation
        if {!$or || $next eq ""} {
          dict with opts {lappend -errorcode $e}
          return -options $opts $errMsg
        }
      } trap {} {errMsg opts} {
        # wrap any other error report
        puts opts=$opts
        throw {DJDSL CTX FAILED EXPR} $errMsg
      } finally {
        set explicitNexts [::djdsl::ctx::callContext clear]
      }
    }

    # puts stderr "+++++ explicits? $explicitNexts"
    if {!$explicitNexts && $next ne ""} {
      $next validate2 inplace -or=$or -and=$and $e $validators
    }

    if {$atHead} {
      $e object mixins clear
    }
    return
  }

  AssetElement public method isValid {-or:switch -outplace:switch args} {
    if {$or} {
      :isValid2 -or {*}$args
    } else {
      :isValid2 -and {*}$args
    }
  }
  
  AssetElement public method isValid2 {-or:switch -and:switch -outplace:switch e:object} {
    set mode [expr {$outplace?"outplace":"inplace"}]
    try {
      :validate2 $mode -or=$or -and=$and $e
      return 1
    } trap {DJDSL CTX VIOLATED} {e opts} {
      return 0
    } on error {e opts} {
      return -options $opts $e
    }
  }

  AssetElement variable -accessor public helpers:class
  AssetElement public method "model method" {name params body} {
    if {![info exists :helpers] || ![::nsf::is object ${:helpers}]} {
      :helpers set [namespace eval ::djdsl::ctx::helpers \
                        [list nx::Class create [string trimleft [self] ":"]]]
    }
    ${:helpers} protected method $name $params -returns boolean $body
  }

  Collaboration public method "validate2 inplace" {-or:switch -and:switch e:object args} {
    # set self [self]
    next
    # Only propagate into children at the beginning of a chain of
    # collaborations.
    if {![llength $args]} {
      foreach el [$e info children] {
        # TODO: -type filter for "info precedence"?
        set cl [self]::[[$el info class] info name]
        # puts cl($self)=$cl,[$el info class]
        if {[::nsf::is class $cl] && [$cl info has type AssetElement]} {
          $cl validate2 inplace -or=$or -and=$and $el
        }
      }
    }
  }

  #
  # Minimal frontend API for defining context conditions (inspired by OCL's )
  #

  nx::Object create contextBuilder {
    :require namespace
    :public object method "<- context" {contextClass body} {
      if {![string match "::*" $contextClass]} {
        set ns [uplevel 1 {namespace current}]
        set :contextClass [namespace qualifiers ${ns}::]::$contextClass
      } else {
        set :contextClass $contextClass
      }
      if {$body eq ""} return;
      try {
        apply [list {} $body [self]]
      } finally {
        unset :contextClass
      }
      return
    }

    interp alias {} [self]::cond {} :<- condition
    :public object method "<- condition" {exprBody} {
      ${:contextClass} condition add [Condition new -bodyExpression $exprBody]
      return
    }

    interp alias {} [self]::op {} :<- operation
    :public object method "<- operation" {args} {
      ${:contextClass} model method {*}$args
      return
    }
  }

  interp alias {} [namespace current]::context \
      {} [namespace current]::contextBuilder <- context
  
  namespace export Condition context
} {

  #
  # == Doctests
  #
  
  namespace import ::djdsl::lm::*
  
  #
  # === Exemplary assets for a family of graphs (Chapter 6)
  #
  Asset create Graphs {
    LanguageModel create Graph {
      :property name
      :property -incremental {edges:0..*,type=Graph::Edge,substdefault {[list]}} {
        :public object method value=size {obj prop} {
          llength [:$obj $prop get]
        }


        :public object method value=forAll {obj prop as body} {
          # TODO: rather use lmap?
          set all [$obj $prop get]
          if {![llength $all]} {return 0}
          upvar 2 $as $as
          foreach $as $all {
            if {![uplevel 2 [list expr $body]]} {
              return 0
            }
          }
          return 1
        }
      }
      :property -incremental {nodes:0..*,type=Graph::Node,substdefault {[list]}}
      
      Classifier create Node
      Classifier create Edge {
        :property -accessor public a:object,type=Node,required
        :property -accessor public b:object,type=Node,required
      }
    }
    
    Collaboration create weighted {
      Classifier create Weight {
        :property -accessor public {value 0}
      }
      Role create Edge {
        :property -accessor public weight:object,type=Weight,required
      }
    }

    #// ctx6b //
    Collaboration create capped {
      :property -accessor public {MAXEDGES:integer 10} 
    }
    #// end //

  }; # Graphs
  
  Asset create Colours {
    Collaboration create coloured {
      Classifier create Color {
        :property -accessor public {value 0}
      }
      Role create Edge {
        :property -accessor public \
            colour:object,type=Color,required
      }
    }
  }; # Colours
  
  set enrichedGraphs [Composition new \
                          -binds {Graphs Colours} \
                          -base [Graphs::Graph] \
                          -features [list [Colours::coloured] [Graphs::weighted] \
                                         [Graphs::capped]]]

  #
  # === An exemplary instantiation (under validation; IuV)
  #

  set IuV [$enrichedGraphs new graph]
  $IuV nodes add [set n1 [$IuV new node]]
  $IuV nodes add [set n2 [$IuV new node]]
  set w [$IuV new weight -value "10"]
  set c [$IuV new color -value "red"]
  $IuV edges add [set edge1 [$IuV new edge -a $n1 -b $n2 -weight $w -colour $c]]

  #
  # The composed language-model is the typical validator for its
  # instantiations. `isValid` returns the condensed boolean
  # result of evaluating the context conditions .
  #

  ? {
    #// ctx1 //
    ${enrichedGraphs}::Graph isValid $IuV
    #// end //
  } 1

  #
  # === Trimming
  #
  # The DSL developer can anchor validation using any collaboration
  # which has previously entered into the composition. This way, the
  # collection of context conditions will be trimmed to match this
  # reduced scope.
  #

  ? {
    #// ctx2 //
    Graphs::weighted isValid $IuV
    #// end //
  } 1

  #
  # === Trimming (cont'd): introduction-only
  #
  # Introduction-only contracts are one trimming variant that
  # anchors validation at the base language-model.
  #

  ? {
    #// ctx3 //
    Graphs::Graph isValid $IuV
    #// end //
  } 1

  #
  # === Chaining
  #

  ? {
    #// ctx4a //
    ${enrichedGraphs}::Graph isValid $IuV; # using conjunction (default)
    #// end //
  } 1

  ? {
    #// ctx4b //
    ${enrichedGraphs}::Graph isValid -or $IuV; # using disjunction
    #// end //
  } 1

  #
  # === Overriding and combination
  #

  #// ctx5 //
  context Graphs::Graph {
    cond {
      ![:edges exists] ||
      [:edges forAll e {
        [$e a get] in [:nodes get] &&
        [$e b get] in [:nodes get]
      }]
    }
  }
  #// end //
  
  ? {
    ${enrichedGraphs}::Graph isValid $IuV
  } 1

  #// ctx6a //
  context Graphs::capped {
    cond {[:MAXEDGES exists] &&
      [:edges size] < [:MAXEDGES get]}
  }
  #// end //

  ? {${enrichedGraphs}::Graph isValid2 -and $IuV} 1

  ? {${enrichedGraphs}::Graph isValid2 $IuV} 1

  $IuV MAXEDGES set 0

  ? {${enrichedGraphs}::Graph isValid $IuV} 0

  Graphs::capped condition unset
  
  ? {${enrichedGraphs}::Graph isValid $IuV} 1

  $IuV MAXEDGES set 10
  #// ctx7 //
  context Graphs::capped {
    cond {
      [:MAXEDGES exists] &&
      [:edges size] < [:MAXEDGES get] &&
      [next]}
  }
  #// end //

  
  ? {${enrichedGraphs}::Graph isValid $IuV} 1

  
  Graphs::capped condition unset

  
  #// ctx8 //
  context Graphs::capped {
    cond {
      [:MAXEDGES exists] &&
      [:edges size] < [:MAXEDGES get] &&
      ![next]}
  }
  #// end //


  ? {${enrichedGraphs}::Graph isValid $IuV} 0


  Graphs::capped condition unset

 
  context Graphs::capped {
    # Is the variable set?
    cond {[:MAXEDGES exists]}
    # Are there fewer than the maximally allowed number of edges?
    cond {[:edges size] < [:MAXEDGES get]}
    # Don't the ancestor conditions hold?
    cond {[next]}
  }
  
  ? {${enrichedGraphs}::Graph isValid $IuV} 1

  # === Templating (incl. model methods)

  #
  # Below, one finds an translation of the OCL constraint expression
  # into a corresponding Tcl +[expr]+.
  #
  # [source,ocl]
  # --------------------------------------------------
  # (edges->notEmpty() and
  # nodes->notEmpty()) implies edges->size()*2 = nodes->size()
  # -------------------------------------------------- 

  #// ctx9 //
  context Graphs::Graph {
    # condition incl. self-call to model method
    cond {[:hasIsolates]}
    # model-method definition
    op hasIsolates {} {
      expr {!([llength ${:edges}] && [llength ${:edges}]) ||
            [llength ${:edges}]*2 == [llength ${:nodes}]}
    } 
  }
  #// end //

  ? {${enrichedGraphs}::Graph isValid $IuV} 1

  #// ctx10 //
  context Graphs::weighted {
    # model-method combination (using [next])
    op hasIsolates {} {
      expr {![:hasLoopEdges] && [next]}
    }
    op hasLoopEdges {} {
      set loopEdges [list]
      foreach e ${:edges} {
        if {[$e a get] eq [$e b get]} {
          return 1
        }
      }
      return 0
    }
  }
  #// end //

  ? {${enrichedGraphs}::Graph isValid $IuV} 1

  ? {Graphs::Graph isValid $IuV} 1
  
}

# Local variables:
#    mode: tcl
#    tcl-indent-level: 2
#    indent-tabs-mode: nil
# End:
#
