import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation } from '@tanstack/react-query';
import { useForm } from 'react-hook-form';
import { Navigate, useLocation, useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Field } from '@/components/Field';
import { Input } from '@/components/ui/input';
import { Spinner } from '@/components/Spinner';
import { isSupabaseConfigured } from '@/lib/supabase';
import { signIn } from '../api';
import { useSession } from '../hooks';
import { loginSchema, type LoginInput } from '../schema';

export function LoginPage() {
  const { session, loading } = useSession();
  const navigate = useNavigate();
  const location = useLocation();
  const from = (location.state as { from?: string } | null)?.from ?? '/';

  const form = useForm<LoginInput>({
    resolver: zodResolver(loginSchema),
    defaultValues: { email: '', password: '' },
  });

  const login = useMutation({
    mutationFn: (v: LoginInput) => signIn(v.email, v.password),
    onSuccess: () => navigate(from, { replace: true }),
    onError: (err) => {
      // Do not reveal whether the email exists.
      const msg = err instanceof Error && /invalid login/i.test(err.message) ? 'Incorrect email or password.' : null;
      form.setError('root', { message: msg ?? (err instanceof Error ? err.message : 'Sign-in failed') });
    },
  });

  if (loading) return <Spinner label="Checking sign-in…" full />;
  if (session) return <Navigate to={from} replace />;

  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-4">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle className="text-xl tracking-wide text-primary">JYOTHI FOODS</CardTitle>
          <CardDescription>Sign in to the ERP</CardDescription>
        </CardHeader>
        <CardContent>
          {!isSupabaseConfigured && (
            <p role="alert" className="mb-3 rounded-md border border-amber-300 bg-amber-50 p-2 text-xs text-amber-900">
              Supabase is not configured. Fill in <code>.env</code> before signing in.
            </p>
          )}
          <form onSubmit={form.handleSubmit((v) => login.mutate(v))} className="space-y-3" noValidate>
            <Field label="Email" htmlFor="email" error={form.formState.errors.email?.message}>
              <Input id="email" type="email" autoComplete="username" autoFocus {...form.register('email')} />
            </Field>
            <Field label="Password" htmlFor="password" error={form.formState.errors.password?.message}>
              <Input id="password" type="password" autoComplete="current-password" {...form.register('password')} />
            </Field>
            {form.formState.errors.root && (
              <p role="alert" className="text-sm text-destructive">
                {form.formState.errors.root.message}
              </p>
            )}
            <Button type="submit" className="w-full" disabled={login.isPending || !isSupabaseConfigured}>
              {login.isPending ? 'Signing in…' : 'Sign in'}
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
