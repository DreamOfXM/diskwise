import { createFileRoute } from "@tanstack/react-router";
import { ComparePage } from "@/components/ComparePage";

export const Route = createFileRoute("/vs/mole/")({
  component: () => <ComparePage slug="mole" locale="zh" />,
});
