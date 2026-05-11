# morph
_morph_ is my (n+1)-th attempt at making a statically typed, compiled language. Let's hope i at least get to something this time...

## Syntax
My goal with the syntax of _morph_ is for it to somewhat resemble mathematical writing. Here's what an example file would look like (wip):

```morph
module Physics

-- Type Aliases using Unicode
type Vector2 = ℝ × ℝ

add : Nat × Nat -> Nat
add x y => x + y

magnitude : Vector2 -> ℝ
magnitude v => {
    val (x, y) = v
    sqrt(add(x^2, y^2))
}

-- Block logic with implicit returns
classify : ℝ -> Set { -1, 0, 1 }
classify n => {
    check {
        | n > 0.0 => 1  -- Positive
        | n < 0.0 => -1 -- Negative
        | otherwise => 0
    }
}
```

## Planned features
- Stronger type inference (Hindley-Milner or something similar)
- Algebraic data types and strong pattern matching
- Lazy evaluation and infinite data structures

## Some issues
There are a _lot_ of them lol
- unsupported operations are typechecked as valid but not implemented in the IR
- global captures are not handled
- the register allocator/codegen combo is quite shaky currently
- no function hoisting
- and probably a lot more that i don't know about yet lol...
