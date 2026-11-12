import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Pencil, Plus } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { DeleteButton } from '@/components/DeleteButton';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { roleLabel } from '@/lib/permissions';
import { deleteRole, listRoles, saveRole, type RoleRow } from '../api';
import { roleFormSchema, type RoleFormInput } from '../schema';

const ROLES_KEY = ['setup', 'roles'] as const;

/**
 * The jobs this shop has.
 *
 * Until db/72 there were eight roles and no ninth, so a shop with a packing
 * section and a night godown had to pretend those people were sales execs.
 * Now the owner names its own, and the permission matrix gets a column for
 * each.
 *
 * Every role is BASED ON one of the eight. That is not a leftover: a handful
 * of rights are asked for by name in the database rather than ticked in the
 * matrix — who may issue a licence, take a backup, run a master reset, create
 * a login — and "like a manager" or "like a store keeper" is the only honest
 * answer a new role can give to those questions. Everything else is the tick
 * boxes, which are the shop's to set per role.
 *
 * It cannot be changed afterwards, because changing it would move everybody
 * holding that role between those hard-wired rights without anyone asking.
 */
export function RolesPanel() {
  const perms = usePermissions();
  const roles = useQuery({ queryKey: ROLES_KEY, queryFn: listRoles });
  const [editing, setEditing] = useState<RoleRow | 'new' | null>(null);

  return (
    <section className="space-y-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 className="text-lg font-semibold">Job roles</h2>
          <p className="max-w-2xl text-sm text-muted-foreground">
            What this shop calls its jobs. Add as many as you need — a role decides which screens a person gets, and
            you set that in Role permissions below. The eight built-in roles can be renamed but not removed.
          </p>
        </div>
        {perms.isOwner && (
          <Button size="sm" onClick={() => setEditing('new')}>
            <Plus /> New role
          </Button>
        )}
      </div>

      {!perms.isOwner && (
        <p className="text-sm text-muted-foreground">
          Only the owner can add or remove a job role. A manager can put people into the roles that exist.
        </p>
      )}

      {roles.isLoading ? (
        <Spinner />
      ) : roles.error ? (
        <p role="alert" className="text-sm text-destructive">
          Could not load the roles: {roles.error.message}
        </p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Role</TableHead>
              <TableHead>Based on</TableHead>
              <TableHead className="text-right">People</TableHead>
              <TableHead className="no-print w-24" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {(roles.data ?? []).map((r) => (
              <TableRow key={r.id} className={r.is_active ? undefined : 'opacity-60'}>
                <TableCell className="font-medium">
                  {r.name}
                  {r.is_system && (
                    <Badge variant="outline" className="ml-2">
                      built-in
                    </Badge>
                  )}
                  {!r.is_active && (
                    <Badge variant="outline" className="ml-2">
                      not in use
                    </Badge>
                  )}
                </TableCell>
                <TableCell className="text-muted-foreground">{roleLabel(r.based_on)}</TableCell>
                <TableCell className="text-right tabular-nums">{r.staff_count}</TableCell>
                <TableCell className="no-print">
                  {perms.isOwner && (
                    <div className="flex justify-end gap-1">
                      <Button variant="ghost" size="icon" aria-label={`Rename ${r.name}`} onClick={() => setEditing(r)}>
                        <Pencil className="h-4 w-4" />
                      </Button>
                      {!r.is_system && <DeleteRole role={r} />}
                    </div>
                  )}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}

      {editing && <RoleDialog role={editing === 'new' ? null : editing} onClose={() => setEditing(null)} />}
    </section>
  );
}

function DeleteRole({ role }: { role: RoleRow }) {
  const queryClient = useQueryClient();
  return (
    <DeleteButton
      label={role.name}
      detail={
        role.staff_count > 0
          ? `${role.staff_count} ${role.staff_count === 1 ? 'person has' : 'people have'} this role. The database will refuse until they are moved to another one.`
          : 'Its permission rows go with it. Nobody holds this role.'
      }
      onDelete={async () => {
        await deleteRole(role.id);
        await queryClient.invalidateQueries({ queryKey: ROLES_KEY });
        await queryClient.invalidateQueries({ queryKey: ['setup', 'role_permissions'] });
        return 'deleted';
      }}
    />
  );
}

function RoleDialog({ role, onClose }: { role: RoleRow | null; onClose: () => void }) {
  const queryClient = useQueryClient();
  const form = useForm<RoleFormInput>({
    resolver: zodResolver(roleFormSchema),
    defaultValues: {
      name: role?.name ?? '',
      based_on: role?.based_on ?? 'sales_exec',
      is_active: role?.is_active ?? true,
    },
  });
  const save = useMutation({
    mutationFn: (v: RoleFormInput) =>
      saveRole(role ? { id: role.id, name: v.name, is_active: v.is_active } : { name: v.name, based_on: v.based_on }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ROLES_KEY });
      await queryClient.invalidateQueries({ queryKey: ['setup', 'role_permissions'] });
      await queryClient.invalidateQueries({ queryKey: ['permissions'] });
      toast({
        title: role ? 'Role saved' : 'Role added',
        description: role ? undefined : 'It starts with the rights of the role it is based on. Change them in Role permissions.',
      });
      onClose();
    },
    onError: (err) => toastError(err, 'Could not save the role'),
  });
  const e = form.formState.errors;

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{role ? `Rename ${role.name}` : 'New job role'}</DialogTitle>
          <DialogDescription>
            {role
              ? 'The name is yours to change. What it is based on is fixed, because changing it would move everybody holding this role between rights nobody asked to change.'
              : 'Name the job as the shop calls it, then pick the built-in role whose rights it starts from.'}
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="space-y-3" noValidate>
          <Field label="Name" htmlFor="role-name" error={e.name?.message}>
            <Input id="role-name" autoFocus placeholder="Packing in-charge" {...form.register('name')} />
          </Field>
          <Field
            label="Based on"
            htmlFor="role-based"
            error={e.based_on?.message}
            help={
              role
                ? 'Fixed once the role exists.'
                : 'Decides the few rights the software asks for by name — the licence, backups, creating logins. Everything else is tick boxes.'
            }
          >
            <NativeSelect id="role-based" disabled={Boolean(role)} {...form.register('based_on')}>
              {/* Owner is not offered: there is one owner, and a role based on
                  it would be a second one with no way to tell them apart. */}
              <option value="admin">Manager — everything except the licence</option>
              <option value="accountant">Accountant — billing, collection, payments</option>
              <option value="store_keeper">Store keeper — buying and stock</option>
              <option value="production_head">Production head — recipes and batches</option>
              <option value="chief">Chief — today's batch only</option>
              <option value="driver">Driver — delivery and collection</option>
              <option value="sales_exec">Sales / counter — billing only</option>
            </NativeSelect>
          </Field>
          {role && (
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" className="h-4 w-4" {...form.register('is_active')} />
              In use — an unused role stays on the list but is not offered when adding a person
            </label>
          )}
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={save.isPending}>
              {save.isPending ? 'Saving…' : 'Save'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
