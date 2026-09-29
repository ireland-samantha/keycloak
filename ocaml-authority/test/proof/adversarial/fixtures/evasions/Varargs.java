package adv.evasions;

import java.util.List;

/** Attack 2h: varargs. */
public interface Varargs {

    void grant(String... scopes);

    void mixed(int n, Scope... scopes);

    <T> List<T> listOf(T... items);

    void commented(String /* ... */ plain);
}
