package adv.evasions;

import java.util.Set;

/** Attack 2b: another nested type Entry, with behaviour; and references to both. */
public class Right {

    public static class Entry {
        public int value;

        public void touch() {
        }
    }

    public Set<Entry> mine() {
        return null;
    }

    public Set<Left.Entry> theirs() {
        return null;
    }
}
