import { useState, type FormEvent } from 'react';
import { Field } from '@/components/Field';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { checkConnection, saveConnection } from '@/lib/config';
import { isDesktop } from '@/lib/desktop';

/**
 * First run on a fresh machine: which database does this copy talk to? Shown instead of
 * the app until it is answered, and never shown at all when the build already carries
 * the project (the web build does). Saving reloads so one client is built with it.
 */
export function ConnectPage() {
  const [url, setUrl] = useState('');
  const [key, setKey] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const onSubmit = async (ev: FormEvent) => {
    ev.preventDefault();
    setBusy(true);
    setError(null);
    const conn = { url: url.trim(), anonKey: key.trim() };
    const problem = await checkConnection(conn);
    if (problem) {
      setError(problem);
      setBusy(false);
      return;
    }
    try {
      saveConnection(conn);
    } catch {
      setError('This machine will not let the app remember settings. Check the browser is not in private mode.');
      setBusy(false);
      return;
    }
    window.location.reload();
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-4">
      <Card className="w-full max-w-lg">
        <CardHeader>
          <CardTitle className="text-xl tracking-wide text-primary">JYOTHI FOODS · ERP</CardTitle>
          <CardDescription>
            One-time setup on {isDesktop() ? 'this computer' : 'this browser'}. Paste the two lines from the Supabase
            dashboard, under <strong>Settings → API</strong>. Everyone in the business uses the same two.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={onSubmit} className="space-y-3" noValidate>
            <Field label="Project URL" htmlFor="cn-url" help="Looks like https://abcdefgh.supabase.co">
              <Input id="cn-url" inputMode="url" autoFocus placeholder="https://….supabase.co" value={url} onChange={(e) => setUrl(e.target.value)} disabled={busy} />
            </Field>
            <Field label="Anon public key" htmlFor="cn-key" help="The long key marked anon / public. Never the service role key.">
              <Textarea id="cn-key" rows={3} className="font-mono text-xs" placeholder="eyJhbGciOi…" value={key} onChange={(e) => setKey(e.target.value)} disabled={busy} />
            </Field>
            {error && (
              <p role="alert" className="rounded-md border border-destructive/40 bg-destructive/5 p-2 text-sm text-destructive">
                {error}
              </p>
            )}
            <Button type="submit" className="w-full" disabled={busy || !url.trim() || !key.trim()}>
              {busy ? 'Checking…' : 'Connect'}
            </Button>
          </form>
          <p className="mt-3 text-xs text-muted-foreground">
            The anon key is meant to be shared with the app: every table is guarded by the database itself, so the key
            alone opens nothing. It is kept on this machine only and is not sent anywhere else.
          </p>
        </CardContent>
      </Card>
    </div>
  );
}
