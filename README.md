# morph
_morph_ is my (n+1)-th attempt at making a statically typed, compiled language. Let's hope i at least get to something this time...

## Syntax
My goal with the syntax of _morph_ is for it to somewhat resemble mathematical writing. Here's what an example file would look like:

```morph
module Physics;

// Type Aliases using Unicode
type Vector2 = ℝ × ℝ;

magnitude : Vector2 ⇒ ℝ;
magnitude(v) = {
    val (x, y) = v;
    sqrt(x^2 + y^2)
}

// Block logic with implicit returns
classify : ℝ ⇒ ℤ;
classify(n) = {
    check {
        | n > 0.0 ⇒ 1;  // Positive
        | n < 0.0 ⇒ -1; // Negative
        | otherwise ⇒ 0;
    }
}
```
