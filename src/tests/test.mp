add: Int × Int -> Int;
add(x, y) => {
    let a = x + y;
    a + 1
};

let a = {
    let a = 1 + 2 * (1 - 2);
    let b = 1;
    add(a, b)
};

let b = a + 1;

let c = add(a, b);
