add: Int × Int -> Int;
add(x, y) => x + y;

let a ∈ Bool = 10;
let b = 2;
let z = 4;
let w = if (a > b) { z + 1 } else { z != 1 };
let c = if (a > b) { a + add(a, true) } else { b + add(b, false) };

c
