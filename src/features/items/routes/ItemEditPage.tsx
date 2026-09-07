import { useQuery } from '@tanstack/react-query';
import { Link, useParams } from 'react-router-dom';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { usePermissions } from '@/features/auth/hooks';
import { getItem } from '../api';
import { ItemForm } from '../components/ItemForm';

export function ItemEditPage() {
  const { id } = useParams();
  const perms = usePermissions();
  const isNew = !id || id === 'new';
  const item = useQuery({ queryKey: ['items', 'one', id], queryFn: () => getItem(id ?? ''), enabled: !isNew });

  if (!perms.canEdit('items')) {
    return (
      <div className="space-y-2">
        <p className="text-sm text-muted-foreground">Your role can view items but not change them.</p>
        <Button asChild variant="outline" size="sm">
          <Link to="/items">Back to items</Link>
        </Button>
      </div>
    );
  }
  if (!isNew && item.isLoading) return <Spinner label="Loading item…" />;
  if (!isNew && (item.error || !item.data)) {
    return (
      <p role="alert" className="text-sm text-destructive">
        Could not load this item{item.error ? `: ${item.error.message}` : ''}.
      </p>
    );
  }

  return (
    <div className="space-y-4">
      <PageHeader
        title={isNew ? 'Add product' : `${item.data?.item_code} — ${item.data?.name}`}
        description="Packing and rates live here and only here. Invoices, stock reports and production derive from them."
        actions={
          <Button asChild variant="ghost" size="sm">
            <Link to="/items">← Items</Link>
          </Button>
        }
      />
      <ItemForm key={item.data?.id ?? 'new'} item={item.data ?? undefined} />
    </div>
  );
}
