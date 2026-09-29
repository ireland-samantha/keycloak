package org.example.validation;

import java.lang.annotation.ElementType;
import java.lang.annotation.Target;

/** Support: a Bean-Validation-style constraint. It is checked only when a validator runs, never by javac. */
@Target({ElementType.METHOD, ElementType.PARAMETER, ElementType.FIELD})
public @interface NotNull {
}
