package adv.emit;

/** Attack 3e: a nullary generic getter. The caller picks T; the value is an unchecked cast. */
public interface Notes {

    <T> T getNote();
}
