import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { RotateCcw } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { MODULES, ROLES, type StaffRole } from '@/lib/permissions';
import { listRolePermissions, resetRolePermissions, saveRolePermissions, type PermissionCell } from '../api';

const PERMS_KEY = ['setup', 'role_permissions'] as const;
const EDITABLE_ROLES = ROLES.filter((r) => r.key !== 'owner');
type Flag = 'can_view' | 'can_edit' | 'can_delete';
const FLAGS: { key: Flag; label: string; title: string }[] = [
  { key: 'can_view', label: 'V', title: 'View' },
  { key: 'can_edit', label: 'E', title: 'Edit' },
  { key: 'can_delete', label: 'D', title: 'Delete' },
];

const cellKey = (role: string, module: string) => `${role}:${module}`;

/**
 * Module × role matrix of view / edit / delete. This table is what
 * `can_view()` / `can_edit()` in RLS read, so a change here changes what the
 * database returns — not just what the sidebar shows.
 */
export function PermissionsMatrix({ compact }: { compact?: boolean }) {
  const perms = usePermissions();
  const queryClient = useQueryClient();
  const rows = useQuery({ queryKey: PERMS_KEY, queryFn: listRolePermissions });
  const [draft, setDraft] = useState<Map<string, PermissionCell>>(new Map());
  const [confirmReset, setConfirmReset] = useState(false);

  useEffect(() => {
    if (!rows.data) return;
    const m = new Map<string, PermissionCell>();
    for (const role of EDITABLE_ROLES) {
      for (const mod of MODULES) {
        const found = rows.data.find((r) => r.role === role.key && r.module === mod.key);
        m.set(cellKey(role.key, mod.key), {
          role: role.key,
          module: mod.key,
          can_view: found?.can_view ?? false,
          can_edit: found?.can_edit ?? false,
          can_delete: found?.can_delete ?? false,
        });
      }
    }
    setDraft(m);
  }, [rows.data]);

  const dirty = useMemo(() => {
    if (!rows.data) return false;
    for (const cell of draft.values()) {
      const found = rows.data.find((r) => r.role === cell.role && r.module === cell.module);
      if (
        (found?.can_view ?? false) !== cell.can_view ||
        (found?.can_edit ?? false) !== cell.can_edit ||
        (found?.can_delete ?? false) !== cell.can_delete
      )
        return true;
    }
    return false;
  }, [draft, rows.data]);

  const toggle = (role: StaffRole, module: string, flag: Flag, value: boolean) => {
    setDraft((prev) => {
      const next = new Map(prev);
      const k = cellKey(role, module);
      const cell = next.get(k);
      if (!cell) return prev;
      const updated = { ...cell, [flag]: value };
      // Edit implies view; delete implies edit. Removing view removes both.
      if (flag === 'can_edit' && value) updated.can_view = true;
      if (flag === 'can_delete' && value) {
        updated.can_edit = true;
        updated.can_view = true;
      }
      if (flag === 'can_view' && !value) {
        updated.can_edit = false;
        updated.can_delete = false;
      }
      if (flag === 'can_edit' && !value) updated.can_delete = false;
      next.set(k, updated);
      return next;
    });
  };

  const save = useMutation({
    mutationFn: () => saveRolePermissions([...draft.values()]),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: PERMS_KEY });
      await queryClient.invalidateQueries({ queryKey: ['permissions'] });
      toast({ title: 'Permissions saved', description: 'Users see the change on their next screen load.' });
    },
    onError: (err) => toastError(err, 'Could not save permissions'),
  });

  const reset = useMutation({
    mutationFn: resetRolePermissions,
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: PERMS_KEY });
      await queryClient.invalidateQueries({ queryKey: ['permissions'] });
      setConfirmReset(false);
      toast({ title: 'Permissions reset to defaults' });
    },
    onError: (err) => toastError(err, 'Could not reset permissions'),
  });

  const canEdit = perms.canEdit('setup');

  return (
    <section className="space-y-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 className={compact ? 'text-base font-semibold' : 'text-lg font-semibold'}>Role permissions</h2>
          <p className="max-w-2xl text-sm text-muted-foreground">
            V = view, E = edit, D = delete, per module. The owner always has everything. This is enforced by the
            database: a role without View on Production gets no production rows even by URL.
          </p>
        </div>
        {canEdit && (
          <div className="flex gap-2">
            {perms.isOwner && (
              <Button variant="outline" size="sm" onClick={() => setConfirmReset(true)}>
                <RotateCcw /> Reset to defaults
              </Button>
            )}
            <Button size="sm" onClick={() => save.mutate()} disabled={!dirty || save.isPending}>
              {save.isPending ? 'Saving…' : 'Save changes'}
            </Button>
          </div>
        )}
      </div>

      {rows.isLoading ? (
        <Spinner />
      ) : rows.error ? (
        <p role="alert" className="text-sm text-destructive">
          Could not load permissions: {rows.error.message}
        </p>
      ) : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b bg-muted/40">
                <th scope="col" className="sticky left-0 bg-muted/40 px-2 py-1.5 text-left font-medium">
                  Module
                </th>
                {EDITABLE_ROLES.map((r) => (
                  <th key={r.key} scope="col" colSpan={3} className="border-l px-1 py-1.5 text-center font-medium" title={r.hint}>
                    {r.label}
                  </th>
                ))}
              </tr>
              <tr className="border-b">
                <th scope="col" className="sticky left-0 bg-card px-2 py-1" />
                {EDITABLE_ROLES.map((r) =>
                  FLAGS.map((f) => (
                    <th
                      key={`${r.key}-${f.key}`}
                      scope="col"
                      className={`px-1 py-1 text-center font-normal text-muted-foreground ${f.key === 'can_view' ? 'border-l' : ''}`}
                      title={f.title}
                    >
                      {f.label}
                    </th>
                  )),
                )}
              </tr>
            </thead>
            <tbody>
              {MODULES.map((mod) => (
                <tr key={mod.key} className="border-b last:border-0 hover:bg-muted/30">
                  <th scope="row" className="sticky left-0 bg-card px-2 py-1 text-left font-medium">
                    {mod.label}
                  </th>
                  {EDITABLE_ROLES.map((r) => {
                    const cell = draft.get(cellKey(r.key, mod.key));
                    return FLAGS.map((f) => (
                      <td key={`${r.key}-${f.key}`} className={`px-1 py-1 text-center ${f.key === 'can_view' ? 'border-l' : ''}`}>
                        <Checkbox
                          aria-label={`${r.label}: ${f.title} ${mod.label}`}
                          checked={cell?.[f.key] ?? false}
                          disabled={!canEdit}
                          onChange={(e) => toggle(r.key, mod.key, f.key, e.target.checked)}
                        />
                      </td>
                    ));
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Dialog open={confirmReset} onOpenChange={setConfirmReset}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Reset all permissions?</DialogTitle>
            <DialogDescription>Every role goes back to the built-in defaults. Your edits are lost.</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setConfirmReset(false)}>
              Cancel
            </Button>
            <Button variant="destructive" onClick={() => reset.mutate()} disabled={reset.isPending}>
              Reset
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  );
}
