import { Link } from 'react-router-dom';
import { usePermissions } from '@/features/auth/hooks';

/**
 * A list in Setup that this form needs is empty, so the dropdown above has
 * nothing in it.
 *
 * "in that stock kept it showing nothing." A dropdown holding only "— choose —"
 * does not look like a list waiting to be filled; it looks like the screen is
 * broken, and the person stops. So say which list is empty and link to the page
 * that fills it — where one button adds the standard rows.
 *
 * Somebody without Setup rights is told who to ask instead of being sent to a
 * page that will turn them away.
 */
export function SetupNeeded({
  show,
  what,
  tab,
  where,
}: {
  /** Only once the list has really loaded — an empty list and a loading one look the same. */
  show: boolean;
  /** Plural, lower case: 'units', 'pack types', 'godowns'. */
  what: string;
  /** The Setup tab slug, e.g. 'units' (src/features/setup/steps.tsx). */
  tab: string;
  /** The tab's label as it reads on screen, e.g. 'Units'. */
  where: string;
}) {
  const canSetup = usePermissions().canView('setup');
  if (!show) return null;

  return (
    <p className="text-xs text-destructive">
      No {what} added yet.{' '}
      {canSetup ? (
        <>
          <Link to={`/setup/${tab}`} className="font-medium underline underline-offset-2">
            Setup → {where}
          </Link>{' '}
          has a button that adds the standard ones.
        </>
      ) : (
        <>Ask the owner to add them in Setup → {where}.</>
      )}
    </p>
  );
}
