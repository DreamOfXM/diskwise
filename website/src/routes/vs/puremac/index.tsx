import { createFileRoute } from "@tanstack/react-router";
import { ComparePage } from "@/components/ComparePage";

export const Route = createFileRoute("/vs/puremac/")({
  component: () => <ComparePage slug="puremac" locale="zh" />,
});
