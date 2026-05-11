choose : Int -> Int
choose x => {
    let outer = x + 1
    let left = {
        let outer = outer * 2
        if outer > 10 then outer - x else x - outer
    }
    let right = if x == 4 then {
        let x = 20
        x + outer
    } else {
        let outer = 3
        outer
    }

    left + right + outer
}

choose(4)
