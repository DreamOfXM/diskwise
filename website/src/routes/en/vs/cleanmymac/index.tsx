import { createFileRoute } from "@tanstack/react-router";
import { ComparePage } from "@/components/ComparePage";

export const Route = createFileRoute("/en/vs/cleanmymac/")({
  component: () => <ComparePage slug="cleanmymac" locale="en" />,
});
