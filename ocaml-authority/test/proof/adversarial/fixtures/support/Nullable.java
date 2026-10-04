package org.example.ext;

import java.lang.annotation.ElementType;
import java.lang.annotation.Target;

/** Support: an annotation that happens to be called Nullable. */
@Target({ElementType.METHOD, ElementType.PARAMETER, ElementType.FIELD, ElementType.TYPE_USE})
public @interface Nullable {
}
