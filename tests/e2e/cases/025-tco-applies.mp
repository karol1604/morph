count_helper : Int × Int -> Int
count_helper n acc => {
	if n <= 0 then acc
	else count_helper(n - 1, acc + 1)
}

count : Int -> Int
count n => count_helper(n, 0)

count2 : Int -> Int
count2 n => if n <= 0 then 0 else 1 + count2(n - 1)

count(4294967297)
