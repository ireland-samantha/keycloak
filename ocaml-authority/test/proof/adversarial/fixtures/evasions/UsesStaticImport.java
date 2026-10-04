package adv.evasions;

import static adv.evasions.Outer.Mode;

import java.util.Set;

/** Attack 2d: the static import makes Mode mean Outer.Mode here (JLS 6.4.1), not the top-level enum. */
public interface UsesStaticImport {

    Set<Mode> getModes();
}
