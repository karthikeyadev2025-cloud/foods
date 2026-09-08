import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Download, Pencil, Plus } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { money } from '@/lib/format';
import { ROLES, roleLabel } from '@/lib/permissions';
import { createUser, listStaff, resetPassword, updateStaff, type Staff } from '../api';
import { editUserSchema, newUserSchema, orNull, resetPasswordSchema, type EditUserInput, type NewUserInput, type ResetPasswordInput } from '../schema';

const STAFF_KEY = ['setup', 'staff'] as const;

/** Users: who can sign in, with which role. Creating a login goes through the create-user edge function. */
export function UsersPanel({ compact }: { compact?: boolean }) {
  const perms = usePermissions();
  const me = useMe();
  const staff = useQuery({ queryKey: STAFF_KEY, queryFn: listStaff });
  const [creating, setCreating] = useState(false);
  const [editing, setEditing] = useState<Staff | null>(null);
  const canManage = me.data?.role === 'owner' || me.data?.role === 'admin';

  const onExport = () =>
    exportToExcel(
      'users',
      (staff.data ?? []).map((s) => ({
        Name: s.full_name,
        Phone: s.phone,
        Role: roleLabel(s.role),
        Mestri: s.is_mestry,
        'Daily wage': Number(s.daily_wage ?? 0),
        Active: s.is_active,
        'Can sign in': Boolean(s.auth_uid),
      })),
      'Users',
    );

  return (
    <section className="space-y-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 className={compact ? 'text-base font-semibold' : 'text-lg font-semibold'}>Users</h2>
          <p className="max-w-2xl text-sm text-muted-foreground">
            Staff who sign in, and mestris who run sections. Roles decide what each person can see and change; the
            matrix below is what the database enforces.
          </p>
        </div>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" onClick={onExport} disabled={!staff.data?.length}>
            <Download /> Excel
          </Button>
          {canManage && (
            <Button size="sm" onClick={() => setCreating(true)}>
              <Plus /> Add user
            </Button>
          )}
        </div>
      </div>

      {staff.isLoading ? (
        <Spinner />
      ) : staff.error ? (
        <p role="alert" className="text-sm text-destructive">
          Could not load users: {staff.error.message}
        </p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Phone</TableHead>
                <TableHead>Role</TableHead>
                <TableHead>Mestri</TableHead>
                <TableHead className="text-right">Daily wage</TableHead>
                <TableHead>Status</TableHead>
                {canManage && <TableHead className="w-16 text-right">Actions</TableHead>}
              </TableRow>
            </TableHeader>
            <TableBody>
              {(staff.data ?? []).map((s) => (
                <TableRow key={s.id}>
                  <TableCell className="font-medium">
                    {s.full_name}
                    {s.id === me.data?.staff_id && <span className="ml-2 text-xs text-muted-foreground">(you)</span>}
                  </TableCell>
                  <TableCell>{s.phone ?? '—'}</TableCell>
                  <TableCell>
                    <Badge variant={s.role === 'owner' ? 'default' : 'secondary'}>{roleLabel(s.role)}</Badge>
                  </TableCell>
                  <TableCell>{s.is_mestry ? 'Yes' : '—'}</TableCell>
                  <TableCell className="num">{money(s.daily_wage)}</TableCell>
                  <TableCell>
                    {!s.is_active ? (
                      <Badge variant="outline">Inactive</Badge>
                    ) : s.auth_uid ? (
                      'Can sign in'
                    ) : (
                      <span className="text-muted-foreground">No login</span>
                    )}
                  </TableCell>
                  {canManage && (
                    <TableCell className="text-right">
                      <Button variant="ghost" size="icon" aria-label={`Edit ${s.full_name}`} onClick={() => setEditing(s)}>
                        <Pencil />
                      </Button>
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {creating && <NewUserDialog isOwner={perms.isOwner} onClose={() => setCreating(false)} />}
      {editing && (
        <EditUserDialog
          key={editing.id}
          staff={editing}
          isOwner={perms.isOwner}
          isSelf={editing.id === me.data?.staff_id}
          onClose={() => setEditing(null)}
        />
      )}
    </section>
  );
}

function roleOptions(isOwner: boolean) {
  // An admin may not hand out owner/admin (mirrors the edge function).
  return ROLES.filter((r) => isOwner || (r.key !== 'owner' && r.key !== 'admin'));
}

function NewUserDialog({ isOwner, onClose }: { isOwner: boolean; onClose: () => void }) {
  const queryClient = useQueryClient();
  const form = useForm<NewUserInput>({
    resolver: zodResolver(newUserSchema),
    defaultValues: { full_name: '', email: '', password: '', phone: '', role: 'sales_exec', is_mestry: false, daily_wage: 0 },
  });
  const create = useMutation({
    mutationFn: (v: NewUserInput) =>
      createUser({
        email: v.email,
        password: v.password,
        full_name: v.full_name,
        phone: orNull(v.phone),
        role: v.role,
        is_mestry: v.is_mestry,
        daily_wage: v.daily_wage,
      }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: STAFF_KEY });
      toast({ title: 'User created', description: 'They can sign in with the email and password you entered.' });
      onClose();
    },
    onError: (err) => toastError(err, 'Could not create the user'),
  });
  const e = form.formState.errors;
  const role = form.watch('role');

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>New user</DialogTitle>
          <DialogDescription>Creates a login and a staff record in this organisation.</DialogDescription>
        </DialogHeader>
        <form onSubmit={form.handleSubmit((v) => create.mutate(v))} className="grid grid-cols-2 gap-3" noValidate>
          <Field label="Full name" htmlFor="nu-name" error={e.full_name?.message} className="col-span-2">
            <Input id="nu-name" autoFocus {...form.register('full_name')} />
          </Field>
          <Field label="Email (login)" htmlFor="nu-email" error={e.email?.message}>
            <Input id="nu-email" type="email" autoComplete="off" {...form.register('email')} />
          </Field>
          <Field label="Password" htmlFor="nu-password" error={e.password?.message} help="At least 8 characters.">
            <Input id="nu-password" type="password" autoComplete="new-password" {...form.register('password')} />
          </Field>
          <Field label="Phone" htmlFor="nu-phone" error={e.phone?.message}>
            <Input id="nu-phone" inputMode="tel" {...form.register('phone')} />
          </Field>
          <Field
            label="Role"
            htmlFor="nu-role"
            error={e.role?.message}
            help={ROLES.find((r) => r.key === role)?.hint}
          >
            <NativeSelect id="nu-role" {...form.register('role')}>
              {roleOptions(isOwner).map((r) => (
                <option key={r.key} value={r.key}>
                  {r.label}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <Field label="Daily wage (₹)" htmlFor="nu-wage" error={e.daily_wage?.message}>
            <Input id="nu-wage" type="number" step="0.01" className="num" {...form.register('daily_wage')} />
          </Field>
          <label htmlFor="nu-mestri" className="flex items-center gap-2 pt-5 text-sm">
            <Checkbox id="nu-mestri" {...form.register('is_mestry')} />
            Is a mestri (runs a section)
          </label>
          <DialogFooter className="col-span-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={create.isPending}>
              {create.isPending ? 'Creating…' : 'Create user'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function EditUserDialog({
  staff,
  isOwner,
  isSelf,
  onClose,
}: {
  staff: Staff;
  isOwner: boolean;
  isSelf: boolean;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const form = useForm<EditUserInput>({
    resolver: zodResolver(editUserSchema),
    defaultValues: {
      full_name: staff.full_name,
      phone: staff.phone ?? '',
      role: staff.role,
      is_mestry: staff.is_mestry,
      daily_wage: Number(staff.daily_wage ?? 0),
      is_active: staff.is_active,
    },
  });
  const save = useMutation({
    mutationFn: (v: EditUserInput) =>
      updateStaff(staff.id, {
        full_name: v.full_name,
        phone: orNull(v.phone),
        role: v.role,
        is_mestry: v.is_mestry,
        daily_wage: v.daily_wage,
        is_active: v.is_active,
      }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: STAFF_KEY });
      await queryClient.invalidateQueries({ queryKey: ['me'] });
      toast({ title: 'User saved' });
      onClose();
    },
    onError: (err) => toastError(err, 'Could not save the user'),
  });
  const e = form.formState.errors;
  const lockRole = isSelf || (!isOwner && (staff.role === 'owner' || staff.role === 'admin'));
  const [resetting, setResetting] = useState(false);
  const canReset = !isSelf && Boolean(staff.auth_uid) && (isOwner || (staff.role !== 'owner' && staff.role !== 'admin'));

  if (resetting) return <ResetPasswordDialog staff={staff} onClose={() => setResetting(false)} />;

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Edit user</DialogTitle>
          {isSelf ? (
            <DialogDescription>You cannot change your own role or deactivate yourself.</DialogDescription>
          ) : canReset ? (
            <DialogDescription>
              Forgotten password?{' '}
              <button type="button" className="text-primary hover:underline" onClick={() => setResetting(true)}>
                Set a new password
              </button>
            </DialogDescription>
          ) : null}
        </DialogHeader>
        <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid grid-cols-2 gap-3" noValidate>
          <Field label="Full name" htmlFor="eu-name" error={e.full_name?.message} className="col-span-2">
            <Input id="eu-name" autoFocus {...form.register('full_name')} />
          </Field>
          <Field label="Phone" htmlFor="eu-phone" error={e.phone?.message}>
            <Input id="eu-phone" inputMode="tel" {...form.register('phone')} />
          </Field>
          <Field label="Role" htmlFor="eu-role" error={e.role?.message}>
            <NativeSelect id="eu-role" disabled={lockRole} {...form.register('role')}>
              {ROLES.filter((r) => isOwner || lockRole || (r.key !== 'owner' && r.key !== 'admin')).map((r) => (
                <option key={r.key} value={r.key}>
                  {r.label}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <Field label="Daily wage (₹)" htmlFor="eu-wage" error={e.daily_wage?.message}>
            <Input id="eu-wage" type="number" step="0.01" className="num" {...form.register('daily_wage')} />
          </Field>
          <div className="flex flex-col gap-2 pt-5 text-sm">
            <label htmlFor="eu-mestri" className="flex items-center gap-2">
              <Checkbox id="eu-mestri" {...form.register('is_mestry')} />
              Is a mestri
            </label>
            <label htmlFor="eu-active" className="flex items-center gap-2">
              <Checkbox id="eu-active" disabled={isSelf} {...form.register('is_active')} />
              Active (can sign in)
            </label>
          </div>
          <DialogFooter className="col-span-2 pt-2">
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

/** A new password for someone else's login. Goes through the reset-password edge function. */
function ResetPasswordDialog({ staff, onClose }: { staff: Staff; onClose: () => void }) {
  const form = useForm<ResetPasswordInput>({ resolver: zodResolver(resetPasswordSchema), defaultValues: { password: '', confirm: '' } });
  const reset = useMutation({
    mutationFn: (v: ResetPasswordInput) => resetPassword(staff.id, v.password),
    onSuccess: () => {
      toast({ title: `Password changed for ${staff.full_name}`, description: 'Tell them the new password in person; it is not sent anywhere.' });
      onClose();
    },
    onError: (err) => toastError(err, 'Could not change the password'),
  });
  const e = form.formState.errors;
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle>New password for {staff.full_name}</DialogTitle>
          <DialogDescription>Their current password stops working at once. At least 8 characters.</DialogDescription>
        </DialogHeader>
        <form onSubmit={form.handleSubmit((v) => reset.mutate(v))} className="space-y-3" noValidate>
          <Field label="New password" htmlFor="rp-pass" error={e.password?.message}>
            <Input id="rp-pass" type="password" autoComplete="new-password" autoFocus {...form.register('password')} />
          </Field>
          <Field label="Type it again" htmlFor="rp-confirm" error={e.confirm?.message}>
            <Input id="rp-confirm" type="password" autoComplete="new-password" {...form.register('confirm')} />
          </Field>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={reset.isPending}>
              {reset.isPending ? 'Changing…' : 'Change password'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
