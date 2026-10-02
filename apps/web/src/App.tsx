import { BrowserRouter, Route, Routes } from 'react-router-dom'
import { Layout } from './components/Layout'
import { Empty } from './components/ui'
import { Buyer } from './pages/Buyer'
import { Discover } from './pages/Discover'
import { Landing } from './pages/Landing'
import { NewRequest } from './pages/NewRequest'
import { Provider } from './pages/Provider'
import { RequestDetail } from './pages/RequestDetail'
import { Verifier } from './pages/Verifier'

export function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<Layout />}>
          <Route index element={<Landing />} />
          <Route path="discover" element={<Discover />} />
          <Route path="buyer" element={<Buyer />} />
          <Route path="buyer/new" element={<NewRequest />} />
          <Route path="provider" element={<Provider />} />
          <Route path="verifier" element={<Verifier />} />
          <Route path="requests/:id" element={<RequestDetail />} />
          <Route
            path="*"
            element={
              <div className="container page">
                <Empty>Page not found.</Empty>
              </div>
            }
          />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
