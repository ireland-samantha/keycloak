package adv.emit;

/** Attack 3e: enum constants that are legal Java but not legal, or not distinct, OCaml constructors. */
public enum Level {
    LOW,
    Low,
    low,
    _HIDDEN,
    $DOLLAR
}
