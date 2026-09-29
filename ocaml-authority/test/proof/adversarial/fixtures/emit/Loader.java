package adv.emit;

import java.io.IOException;

/** Attack 4 (Checked): a data getter that declares a checked exception. */
public interface Loader {

    String getBody() throws IOException;
}
