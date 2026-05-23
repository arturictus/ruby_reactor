import { BrowserRouter as Router, Routes, Route, Link, useLocation } from 'react-router-dom';
import { LayoutDashboard, Zap, Radio } from 'lucide-react';
import Dashboard from './components/Dashboard';
import LiveView from './components/LiveView';
import ReactorClassInstances from './components/ReactorClassInstances';
import ReactorDetail from './components/ReactorDetail';

const basename = window.RUBY_REACTOR_BASE || '/';

function App() {
  return (
    <Router basename={basename}>
      <div className="min-h-screen bg-slate-950 text-slate-50 font-sans selection:bg-indigo-500/30">
        <header className="border-b border-slate-800/60 bg-slate-900/50 backdrop-blur-xl sticky top-0 z-50">
          <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between">
            <Link to="/" className="flex items-center gap-3 group">
              <div className="p-2 bg-indigo-500/10 rounded-lg group-hover:bg-indigo-500/20 transition-colors">
                <Zap className="w-5 h-5 text-indigo-400 group-hover:text-indigo-300 transition-colors" />
              </div>
              <span className="font-bold text-lg tracking-tight text-white">
                Ruby<span className="text-indigo-400">Reactor</span>
              </span>
            </Link>
            <nav className="flex items-center gap-1">
              <NavLink to="/" icon={<LayoutDashboard className="w-4 h-4" />}>Dashboard</NavLink>
              <NavLink to="/live" icon={<Radio className="w-4 h-4" />}>Live</NavLink>
            </nav>
          </div>
        </header>

        <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <Routes>
            <Route path="/" element={<Dashboard />} />
            <Route path="/live" element={<LiveView />} />
            <Route path="/reactors/by-class/:className" element={<ReactorClassInstances />} />
            <Route path="/reactors/:id" element={<ReactorDetail />} />
          </Routes>
        </main>
      </div>
    </Router>
  );
}

function NavLink({ to, icon, children }: { to: string; icon: React.ReactNode; children: React.ReactNode }) {
  const location = useLocation();
  const isActive = location.pathname === to || (to !== '/' && location.pathname.startsWith(to));

  return (
    <Link
      to={to}
      className={`flex items-center gap-2 px-3 py-2 text-sm font-medium rounded-md transition-all ${
        isActive
          ? 'text-white bg-white/10'
          : 'text-slate-400 hover:text-white hover:bg-white/5'
      }`}
    >
      {icon}
      {children}
    </Link>
  );
}

export default App;
