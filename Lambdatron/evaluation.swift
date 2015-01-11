//
//  evaluation.swift
//  Lambdatron
//
//  Created by Austin Zheng on 11/25/14.
//  Copyright (c) 2014 Austin Zheng. All rights reserved.
//

import Foundation

/// The result of evaluating a function, macro, or special form. Successfully returned values or error messages are
/// encapsulated in each case.
enum EvalResult {
  case Success(ConsValue)
  case Failure(EvalError)
}

/// The result of collecting arguments for function evaluation.
enum CollectResult {
  case Success([ConsValue])
  case Failure(EvalError)
}

func next(input: EvalResult, action: ConsValue -> EvalResult) -> EvalResult {
  switch input {
  case let .Success(s): return action(s)
  case .Failure: return input
  }
}

/// Evaluate a form and return either a success or failure
func evaluate(topLevelForm: ConsValue, ctx: Context) -> EvalResult {
  let result = topLevelForm.evaluate(ctx)
  switch result {
  case let .Success(r): return r.isRecurSentinel ? .Failure(.RecurMisuseError) : result
  case .Failure: return result
  }
}

extension Cons {
  
  /// Evaluate a special form.
  private func evaluateSpecialForm(specialForm: SpecialForm, ctx: Context) -> EvalResult {
    logEval("evaluating as special form: \(self.describe(ctx))")
    // How it works:
    // 1. Arguments are passed in as-is
    // 2. The special form decides whether or not to evaluate or use the arguments
    // 3. The special form returns a value
    let symbols = Cons.collectSymbols(next)
    let result = specialForm.function(symbols, ctx)
    return result
  }
  
  /// Evaluate a built-in function.
  private func evaluateBuiltIn(builtIn: LambdatronBuiltIn, ctx: Context) -> EvalResult {
    logEval("evaluating as built-in function: \(self.describe(ctx))")
    switch Cons.collectValues(next, ctx) {
    case let .Success(values): return builtIn(values, ctx)
    case let .Failure(f): return .Failure(f)
    }
  }
  
  /// Expand and evaluate a macro.
  private func evaluateMacro(macro: Macro, ctx: Context) -> EvalResult {
    logEval("evaluating as macro expansion: \(self.describe(ctx))")
    // How it works:
    // 1. Arguments are passed in as-is
    // 2. The macro uses the arguments and its body to create a replacement form (piece of code) in its place
    // 3. This replacement form is then evaluated to return a value
    let symbols = Cons.collectSymbols(next)
    let expanded = macro.macroexpand(symbols)
    switch expanded {
    case let .Success(v):
      logEval("macroexpansion complete; new form: \(v.describe(ctx))")
      let result = v.evaluate(ctx)
      return result
    case .Failure: return expanded
    }
  }
  
  /// Evaluate a user-defined function.
  private func evaluateFunction(function: Function, ctx: Context) -> EvalResult {
    logEval("evaluating as function: \(self.describe(ctx))")
    // How it works:
    // 1. Arguments are evaluated before the function is ever invoked
    // 2. The function only gets the results of the evaluated arguments, and never sees the literal argument forms
    // 3. The function returns a value
    switch Cons.collectValues(next, ctx) {
    case let .Success(values): return function.evaluate(values)
    case let .Failure(f): return .Failure(f)
    }
  }
  
  /// Evaluate a list with a vector in function position.
  private func evaluateVector(vector: Vector, ctx: Context) -> EvalResult {
    logEval("evaluating as function with vector in function position: \(self.describe(ctx))")
    // How it works:
    // 1. (*vector* *pos*) is translated into (nth *vector* *pos*)
    // 2. Normal function call
    switch Cons.collectValues(self, ctx) {
    case let .Success(args):
      if args.count != 2 {
        // Using vector in fn position disallows the user from specifying a fallback. This is to match Clojure's
        // behavior.
        return .Failure(.ArityError)
      }
      return pr_nth(args, ctx)
    case let .Failure(f): return .Failure(f)
    }
  }
  
  /// Evaluate a list with a map in function position.
  private func evaluateMap(map: Map, ctx: Context) -> EvalResult {
    logEval("evaluating as function with map in function position: \(self.describe(ctx))")
    // How it works:
    // 1. (*map* *args*...) is translated into (get *map* *args*...).
    // 2. Normal function call
    switch Cons.collectValues(self, ctx) {
    case let .Success(args): return pr_get(args, ctx)
    case let .Failure(f): return .Failure(f)
    }
  }
  
  /// Apply the values in the array 'args' to the function 'first'.
  class func apply(first: ConsValue, args: [ConsValue], ctx: Context) -> EvalResult {
    if let builtIn = first.asBuiltIn() {
      return builtIn(args, ctx)
    }
    else if let function = first.asFunction() {
      return function.evaluate(args)
    }
    else if let vector = first.asVector() {
      return args.count == 2 ? pr_nth([first] + args, ctx) : .Failure(.ArityError)
    }
    else if let map = first.asMap() {
      return pr_get([first] + args, ctx)
    }
    else {
      return .Failure(.NotEvalableError)
    }
  }
  
  /// Evaluate this list, treating the first item in the list as something that can be eval'ed.
  func evaluate(ctx: Context) -> EvalResult {
    // This method is run in order to evaluate a list form (a b c d).
    // 'a' must resolve to something that can be used in function position. 'b', 'c', and 'd' are arguments to the
    // function.
    
    // 1: Decide whether 'a' is either a special form or a reference to a macro.
    if let specialForm = asSpecialForm() {
      // Special forms can't be returned by functions or macros, nor can they be evaluated themselves.
      return evaluateSpecialForm(specialForm, ctx: ctx)
    }
    else if let macro = asMacro(ctx) {
      // Macros can't be returned by functions or other macros, nor can they be evaluated themselves.
      return evaluateMacro(macro, ctx: ctx)
    }
    
    // 2: Evaluate the form 'a'.
    let fpItemResult = value.evaluate(ctx)
    switch fpItemResult {
    case let .Success(fpItem):
      // 3: Decide whether or not the evaluated form of 'a' is something that can be used in function position.
      if let builtIn = fpItem.asBuiltIn() {
        return evaluateBuiltIn(builtIn, ctx: ctx)
      }
      else if let function = fpItem.asFunction() {
        return evaluateFunction(function, ctx: ctx)
      }
      else if let vector = fpItem.asVector() {
        return evaluateVector(vector, ctx: ctx)
      }
      else if let map = fpItem.asMap() {
        return evaluateMap(map, ctx: ctx)
      }
      else {
        // 3a: 'a' is not something that can be used in function position (e.g. nil)
        return .Failure(.NotEvalableError)
      }
    case .Failure:
      // 2a: Evaluating the form 'a' failed; for example, it was a function that threw some error.
      return fpItemResult
    }
  }
}

extension ConsValue {
  
  func evaluate(ctx: Context) -> EvalResult {
    switch self {
    case FunctionLiteral, BuiltInFunction: return .Success(self)
    case let Symbol(v):
      // Look up the value of v
      switch ctx[v] {
      case .Invalid:
        return .Failure(.InvalidSymbolError)
      case .Unbound:
        return .Failure(.UnboundSymbolError)
      case let .Literal(l):
        return .Success(l)
      case let .Param(p):
        return .Success(p)
      case .BoundMacro:
        return .Failure(.EvaluatingMacroError)
      }
    case NilLiteral, BoolLiteral, IntegerLiteral, FloatLiteral, StringLiteral, Keyword: return .Success(self)
    case let ListLiteral(l):
      // Evaluate the value of the list 'l'
      return l.evaluate(ctx)
    case let VectorLiteral(v):
      // Evaluate the value of the vector literal 'v'
      var buffer : [ConsValue] = []
      for form in v {
        let result = form.evaluate(ctx)
        switch result {
        case let .Success(result): buffer.append(result)
        case .Failure: return result
        }
      }
      return .Success(.VectorLiteral(buffer))
    case let MapLiteral(m):
      // Evaluate the value of the map literal 'm'
      var newMap : Map = [:]
      for (key, value) in m {
        let evaluatedKey = key.evaluate(ctx)
        switch evaluatedKey {
        case let .Success(k):
          let evaluatedValue = value.evaluate(ctx)
          switch evaluatedValue {
          case let .Success(v): newMap[k] = v
          case .Failure: return evaluatedValue
          }
        case .Failure: return evaluatedKey
        }
      }
      return .Success(.MapLiteral(newMap))
    case Special: return .Failure(.EvaluatingSpecialFormError)
    case ReaderMacro: return .Failure(.EvaluatingMacroError)
    case None: return .Failure(.EvaluatingNoneError)
    case RecurSentinel: return .Success(self)
    }
  }
}
