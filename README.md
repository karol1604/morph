# morph
_morph_ is my (n+1)-th attempt at making a statically typed, compiled language. Let's hope i at least get to something this time...

## Syntax
My goal with the syntax of _morph_ is for it to somewhat resemble mathematical writing. Here's what an example file would look like (wip):

```morph
module Physics;

// Type Aliases using Unicode
type Vector2 = ℝ × ℝ;

magnitude : Vector2 -> ℝ;
magnitude(v) = {
    val (x, y) = v;
    sqrt(x^2 + y^2)
}

// Block logic with implicit returns
classify : ℝ -> ℤ;
classify(n) = {
    check {
        | n > 0.0 ⇒ 1;  // Positive
        | n < 0.0 ⇒ -1; // Negative
        | otherwise ⇒ 0;
    }
}
```

## Planned features
- Stronger type inference (Hindley-Milner or something similar)
- Algebraic data types and strong pattern matching
- Lazy evaluation and infinite data structures

## Some issues
There are a _lot_ of them lol
- if an `if` expression has an else branch, both branches don't have to be blocks but if there is no else branch, we assume it's a block
- in the IR, we use strings for names instead of just id's
- the error type is just a `Named` type which is bad
- associativity issue in the type collecting phase for function definitions
- unsupported operations are typechecked as valid but not implemented in the IR
- function-local variables are not scoped in IRGen
- global captures are not handled
- IR uses `OperandType` but we already have the `TypeId` from the checker, we should just use that instead
- the register allocator/codegen combo is quite shaky currently
- stack spills are not handled at all
- no function hoisting
- function type signatures do not check the params and return types correctly. we just use dummy `DOMAIN` and `CODOMAIN` identifiers instead of the actual types
- there is like no tests at all. gotta add snapshot testing for everything
- and probably a lot more that i don't know about yet lol...
