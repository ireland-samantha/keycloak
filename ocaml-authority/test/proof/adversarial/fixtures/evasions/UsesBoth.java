package adv.evasions;

import java.util.Set;

/** Attack 2j: Both is a Policy, and Policy has behaviour. */
public interface UsesBoth {

    Set<Both> all();

    Both one();
}
