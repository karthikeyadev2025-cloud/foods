import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';

/** Stand-in page until the feature's own routes land. Keeps every nav link reachable. */
export function Placeholder({ title, task }: { title: string; task: string }) {
  return (
    <Card className="max-w-xl">
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        <CardDescription>Not built yet — see {task} in docs/BUILD_TASKS.md.</CardDescription>
      </CardHeader>
      <CardContent className="text-sm text-muted-foreground">
        This screen will be driven by its feature folder under <code>src/features/</code>.
      </CardContent>
    </Card>
  );
}
