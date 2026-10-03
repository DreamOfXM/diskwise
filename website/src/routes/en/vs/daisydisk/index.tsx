import { createFileRoute } from "@tanstack/react-router";
import { ComparePage } from "@/components/ComparePage";

export const Route = createFileRoute("/en/vs/daisydisk/")({
  component: () => <ComparePage slug="daisydisk" locale="en" />,
});
