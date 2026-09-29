package adv.emit;

import java.util.Set;

/** Attack 4 (Bounded, Unique): a bound of java.lang.Object, a bound that is a slice enum, a Set of a type variable. */
public interface Boxed<T extends Object, L extends Level> {

    T getValue();

    L getLevel();

    Set<T> getAll();
}
