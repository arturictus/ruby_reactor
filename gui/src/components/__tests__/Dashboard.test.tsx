import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { SWRConfig } from 'swr';
import { describe, it, expect, vi, afterEach } from 'vitest';
import Dashboard from '../Dashboard.tsx';

// 011 US4: the history filter bar appears only when the storage adapter can
// run it, and submits every filter as /api/reactors query params.
function stubApi(executionQuery: boolean) {
  const calls: string[] = [];
  vi.stubGlobal('fetch', vi.fn(async (url: string) => {
    calls.push(url);
    const body = url.includes('/api/capabilities') ? { execution_query: executionQuery } : [];
    return { ok: true, json: async () => body, headers: { get: () => '0' } };
  }));
  return calls;
}

function renderDashboard() {
  return render(
    <SWRConfig value={{ provider: () => new Map(), dedupingInterval: 0 }}>
      <MemoryRouter><Dashboard /></MemoryRouter>
    </SWRConfig>
  );
}

describe('Dashboard history filters', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('hides the filter bar when the storage adapter cannot filter history', async () => {
    const calls = stubApi(false);
    renderDashboard();

    await waitFor(() => expect(calls.some((url) => url.includes('/api/capabilities'))).toBe(true));
    expect(screen.queryByRole('form', { name: 'History filters' })).toBeNull();
  });

  it('requests /api/reactors with the class, status and input filters', async () => {
    const calls = stubApi(true);
    renderDashboard();

    const form = await screen.findByRole('form', { name: 'History filters' });
    fireEvent.change(screen.getByLabelText('Reactor class'), { target: { value: 'ChargeReactor' } });
    fireEvent.change(screen.getByLabelText('Status'), { target: { value: 'completed' } });
    fireEvent.change(screen.getByLabelText('Input name'), { target: { value: 'user_id' } });
    fireEvent.change(screen.getByLabelText('Input value'), { target: { value: '100' } });
    fireEvent.submit(form);

    await waitFor(() => {
      const filtered = calls.find((url) => url.includes('input%5Buser_id%5D=100'));
      expect(filtered).toBeDefined();
      expect(filtered).toContain('class=ChargeReactor');
      expect(filtered).toContain('status=completed');
    });
  });
});
