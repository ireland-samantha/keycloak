package adv.evasions;

import org.example.ext.Policy;

/** Attack 2c: a single-type import of an external type shadows the same-package slice type. */
public interface ImportsExternal {

    Policy imported();
}
