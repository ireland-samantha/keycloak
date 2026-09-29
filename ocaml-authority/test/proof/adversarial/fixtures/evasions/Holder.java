package adv.evasions;

import java.util.Set;

/** Attack 2c: a fully-qualified external type with the simple name of a slice type. */
public interface Holder {

    org.example.ext.Policy external();

    Policy internal();

    adv.evasions.Policy qualified();

    Set<org.example.ext.Policy> externals();
}
