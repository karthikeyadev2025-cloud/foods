import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useForm } from 'react-hook-form';
import { useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Field } from '@/components/Field';
import { Input } from '@/components/ui/input';
import { toastError } from '@/hooks/use-toast';
import { bootstrapOrg, signOut } from '../api';
import { useSession } from '../hooks';
import { bootstrapSchema, type BootstrapFormInput } from '../schema';

/**
 * First run. The signed-in user has no staff row, so nothing in the app can load.
 * One form creates the org and makes them owner, then the setup wizard takes over.
 */
export function WelcomePage() {
  const { session } = useSession();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const form = useForm<BootstrapFormInput>({
    resolver: zodResolver(bootstrapSchema),
    defaultValues: { orgName: 'JYOTHI FOODS', fullName: '', phone: '' },
  });

  const create = useMutation({
    mutationFn: (v: BootstrapFormInput) =>
      bootstrapOrg({ orgName: v.orgName, fullName: v.fullName, phone: v.phone || undefined }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['me'] });
      navigate('/setup/wizard', { replace: true });
    },
    onError: (err) => toastError(err, 'Could not create the organisation'),
  });

  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-4">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle>Welcome</CardTitle>
          <CardDescription>
            Signed in as <span className="font-medium text-foreground">{session?.user.email}</span>. This login is
            not yet attached to an organisation. Create one to become its owner.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={form.handleSubmit((v) => create.mutate(v))} className="space-y-3" noValidate>
            <Field label="Organisation / trade name" htmlFor="orgName" error={form.formState.errors.orgName?.message}>
              <Input id="orgName" {...form.register('orgName')} />
            </Field>
            <Field label="Your name" htmlFor="fullName" error={form.formState.errors.fullName?.message}>
              <Input id="fullName" autoFocus {...form.register('fullName')} />
            </Field>
            <Field label="Phone" htmlFor="phone" error={form.formState.errors.phone?.message}>
              <Input id="phone" inputMode="tel" {...form.register('phone')} />
            </Field>
            <div className="flex items-center justify-between pt-1">
              <Button type="button" variant="ghost" size="sm" onClick={() => void signOut()}>
                Sign out
              </Button>
              <Button type="submit" disabled={create.isPending}>
                {create.isPending ? 'Creating…' : 'Create organisation'}
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
