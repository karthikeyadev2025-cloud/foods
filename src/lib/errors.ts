/**
 * Reading a failure, from anywhere.
 *
 * A Supabase failure is a plain object — `{ message, code, details, hint }` —
 * not an Error, so the obvious `err instanceof Error ? err.message : String(err)`
 * turns every database refusal into the string "[object Object]". That is how a
 * carefully worded message ("...it is already on 3 stock movements. Set it
 * inactive instead") reached the screen as nothing at all.
 *
 * It lives here rather than inside the toast because the toast is not the only
 * place a failure is shown, and the second place is where it went wrong.
 */
export interface PgLikeError {
  message?: string;
  code?: string;
  details?: string;
  hint?: string;
}

function asObject(err: unknown): PgLikeError {
  return (typeof err === 'object' && err !== null ? err : {}) as PgLikeError;
}

/** The sentence to show a person. Never empty, never "[object Object]". */
export function errorMessage(err: unknown): string {
  const e = asObject(err);
  if (e.message) return e.message;
  if (err instanceof Error && err.message) return err.message;
  if (typeof err === 'string' && err) return err;
  return 'Something went wrong. Please try again.';
}

/** The Postgres SQLSTATE where there is one, for the log. */
export function errorCode(err: unknown): string | undefined {
  return asObject(err).code;
}

/** The extra lines Postgres attaches. Worth logging; rarely worth showing. */
export function errorDetail(err: unknown): string {
  const e = asObject(err);
  return [e.details, e.hint].filter(Boolean).join(' ');
}
