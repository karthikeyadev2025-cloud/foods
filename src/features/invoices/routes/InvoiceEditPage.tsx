import { useQuery } from '@tanstack/react-query';
import { Link, useParams } from 'react-router-dom';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { usePermissions } from '@/features/auth/hooks';
import { getInvoice, getInvoiceLines } from '../api';
import { InvoiceEditor } from '../components/InvoiceEditor';

export function InvoiceEditPage() {
  const { id } = useParams();
  const perms = usePermissions();
  const isNew = !id || id === 'new';
  const invoice = useQuery({ queryKey: ['invoices', 'one', id], queryFn: () => getInvoice(id ?? ''), enabled: !isNew });
  const lines = useQuery({ queryKey: ['invoices', 'lines', id], queryFn: () => getInvoiceLines(id ?? ''), enabled: !isNew });

  if (isNew && !perms.canEdit('invoices')) {
    return (
      <div className="space-y-2">
        <p className="text-sm text-muted-foreground">Your role can view invoices but not create them.</p>
        <Button asChild variant="outline" size="sm">
          <Link to="/invoices">Back to invoices</Link>
        </Button>
      </div>
    );
  }
  if (!isNew && (invoice.isLoading || lines.isLoading)) return <Spinner label="Loading invoice…" />;
  if (!isNew && (invoice.error || !invoice.data || lines.error)) {
    return (
      <p role="alert" className="text-sm text-destructive">
        Could not load this invoice{invoice.error ? `: ${invoice.error.message}` : ''}.
      </p>
    );
  }

  return (
    <div className="space-y-4">
      <PageHeader
        title={isNew ? 'New invoice' : `Invoice ${invoice.data?.invoice_no}`}
        actions={
          <Button asChild variant="ghost" size="sm">
            <Link to="/invoices">← Invoices</Link>
          </Button>
        }
      />
      <InvoiceEditor
        key={`${invoice.data?.id ?? 'new'}-${invoice.data?.status ?? ''}`}
        invoice={invoice.data ?? undefined}
        lineRows={lines.data ?? undefined}
      />
    </div>
  );
}
