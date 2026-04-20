fib: Int -> Int;
fib(n) => {
    if n < 2 {
        n
    } else {
        fib(n - 1) + fib(n - 2)
    }
};

factorial: Int -> Int;
factorial(n) => {
    if n < 2 {
        1
    } else {
        n * factorial(n - 1)
    }
};

sumTo: Int -> Int;
sumTo(n) => {
    if n < 1 {
        0
    } else {
        n + sumTo(n - 1)
    }
};

power: Int × Int -> Int;
power(base, exp) => {
    if exp < 1 {
        1
    } else {
        base * power(base, exp - 1)
    }
};

let a = factorial(6);
let b = fib(10);
let c = sumTo(10);
let d = power(2, 8);

let res = a + b + c + d;
if res > 255 {
	1
} else {
	res
}
