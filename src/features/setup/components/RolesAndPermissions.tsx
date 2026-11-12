import { PermissionsMatrix } from './PermissionsMatrix';
import { RolesPanel } from './RolesPanel';

/**
 * The roles and the matrix on one page, in that order: you name the job first,
 * then tick what it may do. Separating them would mean adding a role on one
 * screen and hunting for its column on another.
 */
export function RolesAndPermissions() {
  return (
    <div className="space-y-8">
      <RolesPanel />
      <PermissionsMatrix />
    </div>
  );
}
