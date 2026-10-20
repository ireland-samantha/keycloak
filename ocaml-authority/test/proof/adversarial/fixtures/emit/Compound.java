package adv.emit;

import java.util.List;
import java.util.Map;
import java.util.Set;

/** Attack 4 (Unique, Keyed, Represent): element and key types outside the rule table's list. */
public interface Compound {

    Set<List<String>> getLists();

    Set<String[]> getArrays();

    Map<Set<String>, String> getBySet();

    Set<? extends Level> getLevels();

    Set<Level> getPlainLevels();

    List<? super Integer> getSink();

    Set<_Hidden> getHidden();
}
