# SUI AMM Web Demo

Beautiful web interfaces for viewing LP positions and NFT metadata.

## 📁 Files

### 1. **LP Position Viewer** (`lp-position-viewer.html`)
Interactive dashboard to view and manage liquidity positions.

**Features:**
- 💎 Beautiful glassmorphism design
- 📊 Real-time position values
- 💰 Pending fees display
- 📈 Impermanent loss tracking
- 🎨 Responsive grid layout

### 2. **NFT Gallery** (`nft-gallery.html`)
Stunning gallery for LP Position NFTs with on-chain rendered SVGs.

**Features:**
- 🎨 Beautiful gradient backgrounds
- 🔍 Filter by pool type, token pair, or ID
- 📱 Fully responsive design
- ✨ Smooth animations and hover effects
- 🖼️ Modal view for detailed metadata
- 💾 SVG export capability (demo)

---

## 🚀 Quick Start

### Option 1: Open Directly
Simply open the HTML files in your web browser:

```bash
# From the demo/web directory
open lp-position-viewer.html
open nft-gallery.html

# Or on Linux
xdg-open lp-position-viewer.html
xdg-open nft-gallery.html
```

### Option 2: Local Web Server
For better experience, serve via HTTP:

```bash
# Using Python 3
python3 -m http.server 8000

# Using Node.js (if you have npx)
npx http-server

# Then open: http://localhost:8000/lp-position-viewer.html
```

---

## 📸 Screenshots

### LP Position Viewer
- Clean, modern interface
- Displays position values in both tokens
- Shows pending fees ready to claim
- Color-coded impermanent loss indicators
- Entry price tracking

### NFT Gallery
- Gorgeous gradient cards for each NFT
- Filter and search functionality
- Modal popup for detailed view
- On-click interactions
- Beautiful animations

---

## 🎨 Design Features

### Visual Design
- **Glassmorphism** - Frosted glass effect with backdrop blur
- **Gradients** - Vibrant color gradients for visual appeal
- **Animations** - Smooth transitions and hover effects
- **Responsive** - Works on desktop, tablet, and mobile

### UX Patterns
- **Immediate Feedback** - Hover states and transitions
- **Clear Hierarchy** - Important info prominently displayed
- **Intuitive Layout** - Grid-based responsive design
- **Accessible** - High contrast, readable fonts

---

## 🔧 Customization

### Adding Real Data

To connect to real blockchain data, replace the sample data with API calls:

```javascript
// Example: Fetch real positions
async function loadPositions() {
    const address = document.getElementById('addressInput').value;
    
    // Call Sui RPC
    const response = await fetch('https://fullnode.testnet.sui.io', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'suix_getOwnedObjects',
            params: [address, { filter: { StructType: 'PACKAGE_ID::position::LPPosition' } }]
        })
    });
    
    const data = await response.json();
    // Process and display real positions
}
```

### Styling Customization

Modify the CSS variables for quick theme changes:

```css
/* Change color scheme */
body {
    background: linear-gradient(135deg, #YOUR-COLOR-1 0%, #YOUR-COLOR-2 100%);
}

/* Adjust card styles */
.position-card {
    background: rgba(255, 255, 255, 0.15);
    border-radius: 20px;
}
```

---

## 📋 Features Checklist

### LP Position Viewer
- [x] Display position metadata
- [x] Show current values
- [x] Display pending fees
- [x] Impermanent loss calculation
- [x] Responsive design
- [ ] Connect to Sui wallet (production)
- [ ] Real-time updates (production)
- [ ] Transaction actions (production)

### NFT Gallery
- [x] Grid layout display
- [x] Filter by pool type
- [x] Filter by token pair
- [x] Search by ID
- [x] Modal detail view
- [x] Beautiful animations
- [ ] Connect to Sui NFT data (production)
- [ ] Actual SVG rendering from on-chain data
- [ ] Transfer functionality (production)

---

## 🌐 Browser Compatibility

Tested and works on:
- ✅ Chrome/Edge (latest)
- ✅ Firefox (latest)
- ✅ Safari (latest)
- ✅ Mobile browsers

**Requirements:**
- Modern browser with CSS Grid support
- JavaScript enabled
- Backdrop-filter support (for blur effects)

---

## 🔮 Future Enhancements

### Planned Features
1. **Wallet Integration**
   - Connect via Sui Wallet
   - Sign transactions directly
   - Real-time balance updates

2. **Live Data**
   - Fetch positions from blockchain
   - Real-time price updates
   - Live fee accrual tracking

3. **Advanced Features**
   - Claim fees directly from UI
   - Compound fees with one click
   - Transfer positions to other wallets
   - Export position history

4. **Analytics**
   - Historical performance charts
   - Fee earnings over time
   - IL tracking charts
   - Volume analytics

---

## 💡 Usage Tips

### Demo Mode
Both interfaces include sample data for demonstration:
- **LP Viewer:** Enter "demo" or leave blank to load samples
- **NFT Gallery:** Pre-loaded with 6 sample NFTs

### Navigation
- Click cards for detailed views
- Use filters to narrow results
- Hover for interactive effects
- Mobile-friendly touch interactions

### Best Practices
- Use with local server for best performance
- Modern browser recommended
- Enable JavaScript for full functionality

---

## 📝 Notes

### Sample Data
All data shown is for demonstration purposes. In production:
- Connect to Sui blockchain via RPC
- Fetch real LP positions and NFT metadata
- Display actual on-chain SVG images
- Enable real transactions

### Security
For production deployment:
- Validate all user inputs
- Use HTTPS only
- Implement proper authentication
- Audit smart contract interactions

---

## 🤝 Contributing

To improve these interfaces:
1. Fork the repository
2. Make your changes
3. Test across browsers
4. Submit a pull request

---

## 📄 License

These demo interfaces are part of the SUI AMM project.

---

**Built with ❤️ for the Sui ecosystem**
