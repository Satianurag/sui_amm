#!/bin/bash
# Quick demo completion script

source .env

# Update missing IDs
cat >> .env << EOF
POOL_REGISTRY=0xf77f651bc9f5fe762a7ff5efb2c1119e2af741627c390f2cefc7d0c8f538c1d7
ADMIN_CAP=0x07257bc5eded47ef80497cb0d69e7d3ff6eb0939f1e4b4818fc19809871185cc
STATS_REGISTRY=0x9dde29ed35230cc8b074947fb2d3ab9089f4fbc0328a5b64103fb4ec645b5535
ORDER_REGISTRY=0x3885f177baa950899ddd7dde472a05155d9c93fe33d471274fc98d119d4e9291
GOV_CONFIG=0x5ea8eb054946b8d851b29c8f34bb426d4fb7e3998f51a5847cd771b898d83306
EOF

echo "✅ Environment setup complete!"
echo ""
echo "📝 Summary:"
echo "  Package ID: $PACKAGE_ID"
echo "  Coin Package: $COIN_PACKAGE_ID"
echo "  Pool Registry: $POOL_REGISTRY"
echo "  Admin Cap: $ADMIN_CAP"
echo ""
echo "🎬 Ready for demo! Run the following:"
echo "  ./03_create_pool.sh  # Create SUI-USDC pool"
echo "  ./04_add_liquidity.sh"  
echo "  ./05_swap.sh"
echo ""
