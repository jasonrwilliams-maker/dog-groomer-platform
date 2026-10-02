import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Check-in · Paws & Polish",
  description: "The groomer's check-in screen: is this dog cleared for today's groom?",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen antialiased">{children}</body>
    </html>
  );
}
