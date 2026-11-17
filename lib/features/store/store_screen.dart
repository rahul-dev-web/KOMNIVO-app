import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key, required this.preview});

  final bool preview;

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  String? _activeCategory;
  String _query = '';
  late final List<_StoreListing> _listings = List<_StoreListing>.from(_sampleListings);
  List<Map<String, dynamic>> _cartItems = [];
  bool _isLoading = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    if (!widget.preview) _loadMarketplace();
  }

  _StoreListing _listingFromRow(Map<String, dynamic> row) {
    final key = row['category_key']?.toString() ?? 'assets';
    final seller = row['seller'] is Map
        ? Map<String, dynamic>.from(row['seller'] as Map)
        : <String, dynamic>{};
    return _StoreListing(
      id: row['id']?.toString() ?? '',
      categoryKey: key,
      title: row['title']?.toString() ?? 'Untitled listing',
      role: row['role']?.toString() ?? '',
      description: row['description']?.toString() ?? '',
      priceValue: (row['price_amount'] as num?)?.toDouble() ?? 0,
      pricingMode: row['pricing_model']?.toString() ?? 'fixed',
      icon: _categoryFor(key).icon,
      game: row['game']?.toString() ?? '',
      region: row['region']?.toString() ?? 'Remote',
      isSample: false,
      sellerId: row['seller_id']?.toString() ?? '',
      sellerName: seller['display_name']?.toString() ?? 'KOMNIVO seller',
    );
  }

  Future<void> _loadMarketplace() async {
    if (!mounted) return;
    setState(() { _isLoading = true; _loadError = null; });
    try {
      final results = await Future.wait([
        KomnivoRepository.instance.storeListings(),
        KomnivoRepository.instance.storeCartItems(),
      ]);
      final live = (results[0] as List<Map<String, dynamic>>).map(_listingFromRow).toList();
      if (!mounted) return;
      setState(() {
        _listings.removeWhere((item) => !item.isSample);
        _listings.insertAll(0, live);
        _cartItems = results[1] as List<Map<String, dynamic>>;
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  int get _cartCount => _cartItems.fold<int>(
      0, (sum, item) => sum + ((item['quantity'] as num?)?.toInt() ?? 1));

  double get _cartTotal => _cartItems.fold<double>(0, (sum, item) {
    final raw = item['store_listings'];
    if (raw is! Map) return sum;
    final listing = Map<String, dynamic>.from(raw);
    return sum + ((listing['price_amount'] as num?)?.toDouble() ?? 0) *
        ((item['quantity'] as num?)?.toInt() ?? 1);
  });

  _StoreCategory? get _selectedCategory {
    for (final category in _storeCategories) {
      if (category.key == _activeCategory) return category;
    }
    return null;
  }

  List<_StoreListing> get _visibleListings {
    final normalizedQuery = _query.trim().toLowerCase();
    return _listings.where((listing) {
      final matchesCategory = _activeCategory == null || listing.categoryKey == _activeCategory;
      final searchable = [
        listing.title,
        listing.role,
        listing.description,
        listing.game,
        listing.region,
        _categoryFor(listing.categoryKey).title,
      ].join(' ').toLowerCase();
      return matchesCategory && (normalizedQuery.isEmpty || searchable.contains(normalizedQuery));
    }).toList();
  }

  void _openCategory(_StoreCategory category) {
    setState(() {
      _activeCategory = category.key;
      _query = '';
    });
  }

  void _backToStoreHome() {
    setState(() {
      _activeCategory = null;
      _query = '';
    });
  }

  Future<void> _addToStore() async {
    final listing = await showDialog<_StoreListing>(
      context: context,
      builder: (_) => _AddStoreListingDialog(initialCategory: _selectedCategory),
    );
    if (listing == null || !mounted) return;

    setState(() {
      _listings.insert(0, listing);
      _activeCategory = listing.categoryKey;
      _query = '';
    });
    showMessage(context, 'Listing added to this session. Backend publishing is not connected yet.');
  }

  void _showListingDetails(_StoreListing listing) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final category = _categoryFor(listing.categoryKey);
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(22, 22, 16, 8),
          contentPadding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          title: Row(
            children: [
              _ListingAvatar(icon: listing.icon, tint: category.tint, size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  listing.title,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CategoryPill(label: category.title, tint: category.tint),
                  const SizedBox(height: 13),
                  Text(
                    listing.role,
                    style: const TextStyle(color: KomnivoTheme.cyan, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(listing.description, style: const TextStyle(color: Colors.white70, height: 1.5)),
                  const SizedBox(height: 16),
                  if (listing.game.isNotEmpty)
                    _DetailLine(icon: Icons.sports_esports_outlined, label: 'Game / Speciality', value: listing.game),
                  if (listing.region.isNotEmpty)
                    _DetailLine(icon: Icons.public_outlined, label: 'Availability', value: listing.region),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: KomnivoTheme.surfaceRaised,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: KomnivoTheme.line),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'LISTED PRICE',
                          style: TextStyle(color: KomnivoTheme.muted, fontSize: 9, letterSpacing: 1, fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 5),
                        Text(listing.priceLabel, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                      ],
                    ),
                  ),
                  if (listing.isSample) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Sample listing for the Store UI. This is not a real seller profile or offer.',
                      style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
            if (listing.isSample)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('DEMO ONLY', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10, fontWeight: FontWeight.w900)),
              )
            else if (listing.canPurchase) ...[
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _addListingToCart(listing);
                },
                icon: const Icon(Icons.add_shopping_cart, size: 17),
                label: const Text('Add to cart'),
              ),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _buyNow(listing);
                },
                icon: const Icon(Icons.shopping_bag_outlined, size: 17),
                label: const Text('Buy now'),
              ),
            ] else
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _requestService(listing);
                },
                icon: const Icon(Icons.chat_bubble_outline, size: 17),
                label: const Text('Request via WhatsApp'),
              ),
          ],
        );
      },
    );
  }

  Future<void> _addToStore() async {
    final draft = await showDialog<_StoreListing>(
      context: context,
      builder: (_) => _AddStoreListingDialog(initialCategory: _selectedCategory),
    );
    if (draft == null || !mounted) return;
    try {
      if (widget.preview) {
        setState(() {
          _listings.insert(0, draft);
          _activeCategory = draft.categoryKey;
          _query = '';
        });
        showMessage(context, 'Preview listing added for this session only.');
        return;
      }
      final row = await KomnivoRepository.instance.createStoreListing(
        categoryKey: draft.categoryKey,
        title: draft.title,
        role: draft.role,
        description: draft.description,
        game: draft.game,
        region: draft.region,
        priceAmount: draft.priceValue,
        pricingModel: draft.pricingMode,
      );
      if (!mounted) return;
      setState(() {
        _listings.insert(0, _listingFromRow(row));
        _activeCategory = draft.categoryKey;
        _query = '';
      });
      showMessage(context, 'Your listing is now published in Store.');
    } catch (error) {
      if (mounted) showMessage(context, 'Could not publish listing: $error');
    }
  }

  Future<void> _refreshCart() async {
    if (widget.preview) return;
    final rows = await KomnivoRepository.instance.storeCartItems();
    if (mounted) setState(() => _cartItems = rows);
  }

  Future<void> _addListingToCart(_StoreListing listing) async {
    if (listing.isSample || widget.preview) {
      showMessage(context, 'Demo listing: checkout is disabled for samples.');
      return;
    }
    try {
      await KomnivoRepository.instance.addStoreCartItem(listing.id);
      await _refreshCart();
      if (mounted) showMessage(context, 'Added to your cart.');
    } catch (error) {
      if (mounted) showMessage(context, 'Could not add to cart: $error');
    }
  }

  Future<void> _openStoreWhatsApp(String message) async {
    final uri = Uri.https('wa.me', '/919981977828', {'text': message});
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      showMessage(context, 'WhatsApp could not be opened. Number: +91 9981977828');
    }
  }

  Future<void> _buyNow(_StoreListing listing) async {
    if (listing.isSample || widget.preview) {
      showMessage(context, 'Demo listing: real orders are disabled for samples.');
      return;
    }
    try {
      final order = await KomnivoRepository.instance.createStoreOrder([
        {'listing_id': listing.id, 'quantity': 1},
      ]);
      final code = order['order_code']?.toString() ?? 'KOMNIVO order';
      final total = (order['subtotal'] as num?)?.toDouble() ?? listing.priceValue;
      await _openStoreWhatsApp(
        'Hello KOMNIVO Store, I want to place this order.\n'
        'Order: ${code}\nItem: ${listing.title}\n'
        'Amount: ₹${total.toStringAsFixed(2)}\n'
        'No payment has been made in the app. Please share the next steps.',
      );
      await _refreshCart();
    } catch (error) {
      if (mounted) showMessage(context, 'Could not create order: $error');
    }
  }

  Future<void> _requestService(_StoreListing listing) async {
    if (listing.isSample || widget.preview) {
      showMessage(context, 'Demo listing: service requests are disabled for samples.');
      return;
    }
    try {
      final inquiry = await KomnivoRepository.instance.createStoreInquiry(
        listingId: listing.id,
        sellerId: listing.sellerId,
        message: 'Interested in ${listing.title}. Please share availability and terms.',
      );
      await _openStoreWhatsApp(
        'Hello KOMNIVO Store, I want to enquire about a service listing.\n'
        'Listing: ${listing.title}\n'
        'Category: ${_categoryFor(listing.categoryKey).title}\n'
        'Pricing: ${listing.priceLabel}\n'
        'Inquiry ID: ${inquiry['id']}\nPlease share the next steps.',
      );
    } catch (error) {
      if (mounted) showMessage(context, 'Could not create inquiry: $error');
    }
  }

  Future<void> _checkoutCart() async {
    if (widget.preview || _cartItems.isEmpty) return;
    final orderItems = _cartItems.map((item) {
      final listing = Map<String, dynamic>.from(item['store_listings'] as Map);
      return {'listing_id': listing['id'], 'quantity': (item['quantity'] as num?)?.toInt() ?? 1};
    }).toList();
    final summary = _cartItems.map((item) {
      final listing = Map<String, dynamic>.from(item['store_listings'] as Map);
      final quantity = (item['quantity'] as num?)?.toInt() ?? 1;
      return '${listing['title']} × ${quantity}';
    }).join('\n');
    try {
      final order = await KomnivoRepository.instance.createStoreOrder(orderItems);
      final code = order['order_code']?.toString() ?? 'KOMNIVO order';
      final total = (order['subtotal'] as num?)?.toDouble() ?? _cartTotal;
      await _openStoreWhatsApp(
        'Hello KOMNIVO Store, please process my order.\n'
        'Order: ${code}\n${summary}\n'
        'Total: ₹${total.toStringAsFixed(2)}\n'
        'No payment has been made in the app. Please share the next steps.',
      );
      await _refreshCart();
      if (mounted) showMessage(context, 'Order request created. Complete the conversation on WhatsApp.');
    } catch (error) {
      if (mounted) showMessage(context, 'Checkout failed: $error');
    }
  }

  void _showCart() {
    if (widget.preview) {
      showMessage(context, 'Cart is available after signing in.');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refreshDialog) => AlertDialog(
          title: Row(
            children: [
              const Expanded(child: Text('Your cart')),
              Text('${_cartCount} items', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: _cartItems.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: EmptyState(
                      title: 'Your cart is empty',
                      message: 'Add a one-time asset or license listing to continue.',
                      icon: Icons.shopping_cart_outlined,
                    ),
                  )
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _cartItems.length,
                      separatorBuilder: (_, __) => const Divider(color: KomnivoTheme.line),
                      itemBuilder: (context, index) {
                        final item = _cartItems[index];
                        final listing = Map<String, dynamic>.from(item['store_listings'] as Map);
                        final quantity = (item['quantity'] as num?)?.toInt() ?? 1;
                        final price = (listing['price_amount'] as num?)?.toDouble() ?? 0;
                        return Row(
                          children: [
                            Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(listing['title']?.toString() ?? 'Listing', style: const TextStyle(fontWeight: FontWeight.w800)),
                                Text('₹${price.toStringAsFixed(2)} each', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
                              ],
                            )),
                            IconButton(
                              tooltip: 'Decrease quantity',
                              onPressed: quantity <= 1 ? null : () async {
                                await KomnivoRepository.instance.updateStoreCartQuantity(item['id'].toString(), quantity - 1);
                                await _refreshCart();
                                refreshDialog(() {});
                              },
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                            Text('${quantity}', style: const TextStyle(fontWeight: FontWeight.w800)),
                            IconButton(
                              tooltip: 'Increase quantity',
                              onPressed: quantity >= 20 ? null : () async {
                                await KomnivoRepository.instance.updateStoreCartQuantity(item['id'].toString(), quantity + 1);
                                await _refreshCart();
                                refreshDialog(() {});
                              },
                              icon: const Icon(Icons.add_circle_outline),
                            ),
                            IconButton(
                              tooltip: 'Remove item',
                              onPressed: () async {
                                await KomnivoRepository.instance.removeStoreCartItem(item['id'].toString());
                                await _refreshCart();
                                refreshDialog(() {});
                              },
                              icon: const Icon(Icons.delete_outline, color: KomnivoTheme.muted),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Continue shopping')),
            if (_cartItems.isNotEmpty)
              FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  await _checkoutCart();
                },
                icon: const Icon(Icons.chat_bubble_outline, size: 17),
                label: Text('Continue · ₹${_cartTotal.toStringAsFixed(0)}'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _storeActions({required bool compact}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Stack(
        clipBehavior: Clip.none,
        children: [
          IconButton.filledTonal(
            tooltip: 'Open cart',
            onPressed: _showCart,
            icon: const Icon(Icons.shopping_cart_outlined),
          ),
          if (_cartCount > 0)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(color: KomnivoTheme.accent, borderRadius: BorderRadius.circular(20)),
                child: Text('${_cartCount}', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900)),
              ),
            ),
        ],
      ),
      const SizedBox(width: 7),
      _addButton(compact: compact),
    ],
  );

  Widget _addButton({required bool compact}) {
    if (compact) {
      return IconButton.filled(
        tooltip: 'Add to Store',
        onPressed: _addToStore,
        icon: const Icon(Icons.add_rounded),
        style: IconButton.styleFrom(
          backgroundColor: KomnivoTheme.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size.square(42),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: _addToStore,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('Add to Store'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 15),
      ),
    );
  }

  Widget _searchField() {
    return TextField(
      onChanged: (value) => setState(() => _query = value),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: _activeCategory == null
            ? 'Search people, teams and assets'
            : 'Search ${_selectedCategory?.title.toLowerCase() ?? 'listings'}',
        prefixIcon: const Icon(Icons.search_rounded, size: 19),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: () => setState(() => _query = ''),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 13),
      ),
    );
  }

  Widget _sidebar(double width) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        border: Border(right: BorderSide(color: KomnivoTheme.line.withValues(alpha: .9))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(width < 150 ? 11 : 17, 17, 12, 5),
            child: const Text(
              'STORE',
              style: TextStyle(color: KomnivoTheme.cyan, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(width < 150 ? 11 : 17, 0, 11, 14),
            child: Text(
              'Discover your next competitive edge.',
              style: TextStyle(color: KomnivoTheme.muted, fontSize: width < 150 ? 10 : 11, height: 1.35),
            ),
          ),
          const Divider(height: 1, color: KomnivoTheme.line),
          const Padding(
            padding: EdgeInsets.fromLTRB(13, 14, 10, 7),
            child: Text(
              'BROWSE CATEGORIES',
              style: TextStyle(color: KomnivoTheme.muted, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 12),
              children: _storeCategories.map((category) => _StoreCategoryTile(
                category: category,
                onTap: () => _openCategory(category),
                narrow: width < 150,
              )).toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: KomnivoTheme.surfaceRaised,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: KomnivoTheme.line),
              ),
              child: Row(
                children: [
                  const Icon(Icons.storefront_outlined, size: 17, color: KomnivoTheme.cyan),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Have something to offer?',
                      style: TextStyle(fontSize: width < 150 ? 9 : 10, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _homeContent() {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(compact ? 13 : 24, 17, compact ? 13 : 24, 13),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Flexible(
                          child: Text(
                            'New in Store',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: -.5),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const _NewBadge(),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Fresh talent, creative assets and esports services.',
                      style: TextStyle(color: KomnivoTheme.muted, fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _storeActions(compact: true),
                    ),
                  ],
                )
              : Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'New in Store',
                                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, letterSpacing: -.5),
                              ),
                              SizedBox(width: 8),
                              _NewBadge(),
                            ],
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Fresh talent, creative assets and esports services.',
                            style: TextStyle(color: KomnivoTheme.muted, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _storeActions(compact: false),
                  ],
                ),
        ),
        if (_isLoading) const LinearProgressIndicator(minHeight: 2),
        if (_loadError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 8, 13, 0),
            child: Text(
              'Live Store could not be loaded: $_loadError',
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 10),
            ),
          ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 13 : 24),
          child: _searchField(),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(compact ? 13 : 24, 15, compact ? 13 : 24, 24),
            children: [
              _StoreHeroBanner(onExplorePlayers: () => _openCategory(_storeCategories[2])),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Expanded(child: Text('Recently added', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900))),
                  const _SampleLabel(),
                  const SizedBox(width: 7),
                  Text(
                    '${_visibleListings.length} listings',
                    style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 11),
              _listingGrid(_visibleListings),
            ],
          ),
        ),
      ],
    );
  }

  Widget _categoryContent() {
    final category = _selectedCategory!;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final listings = _visibleListings;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(compact ? 11 : 22, 13, compact ? 11 : 22, 12),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Back to Store categories',
                          onPressed: _backToStoreHome,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.arrow_back_rounded),
                          style: IconButton.styleFrom(
                            backgroundColor: KomnivoTheme.surfaceRaised,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _ListingAvatar(icon: category.icon, tint: category.tint, size: 38),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                category.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                              ),
                              Text(
                                '${listings.length} available listings',
                                style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _storeActions(compact: true),
                    ),
                  ],
                )
              : Row(
                  children: [
                    IconButton(
                      tooltip: 'Back to Store categories',
                      onPressed: _backToStoreHome,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.arrow_back_rounded),
                      style: IconButton.styleFrom(
                        backgroundColor: KomnivoTheme.surfaceRaised,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _ListingAvatar(icon: category.icon, tint: category.tint, size: 44),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            category.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
                          ),
                          Text(
                            '${listings.length} available listings',
                            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    _storeActions(compact: false),
                  ],
                ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 13 : 22),
          child: _searchField(),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(compact ? 13 : 22, 17, compact ? 13 : 22, 24),
            children: [
              Text(category.subtitle, style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4)),
              const SizedBox(height: 4),
              Text(
                category.description,
                style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4),
              ),
              const SizedBox(height: 13),
              Row(
                children: [
                  const Expanded(child: Text('Explore listings', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900))),
                  const _SampleLabel(),
                ],
              ),
              const SizedBox(height: 10),
              _listingGrid(listings),
            ],
          ),
        ),
      ],
    );
  }

  Widget _listingGrid(List<_StoreListing> listings) {
    if (listings.isEmpty) {
      return const EmptyState(
        title: 'No listings found',
        message: 'Try another search or check back when more offers are published.',
        icon: Icons.storefront_outlined,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final columns = availableWidth >= 980 ? 3 : availableWidth >= 570 ? 2 : 1;
        const spacing = 12.0;
        final cardWidth = (availableWidth - (spacing * (columns - 1))) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: listings.map((listing) => SizedBox(
            width: cardWidth,
            child: _StoreListingCard(
              listing: listing,
              category: _categoryFor(listing.categoryKey),
              onTap: () => _showListingDetails(listing),
            ),
          )).toList(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    // Keep the named categories readable while reserving enough space for
    // listings on phone-sized viewports.
    final sidebarWidth = screenWidth < 600 ? 130.0 : 226.0;
    return Container(
      color: KomnivoTheme.background,
      child: _activeCategory == null
          ? Row(
              children: [
                _sidebar(sidebarWidth),
                Expanded(child: _homeContent()),
              ],
            )
          : _categoryContent(),
    );
  }
}

class _StoreCategory {
  const _StoreCategory({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.icon,
    required this.tint,
    this.isAsset = false,
  });

  final String key;
  final String title;
  final String subtitle;
  final String description;
  final IconData icon;
  final Color tint;
  final bool isAsset;
}

const _storeCategories = <_StoreCategory>[
  _StoreCategory(
    key: 'assets',
    title: 'Assets',
    subtitle: 'Designs, overlays and digital resources.',
    description: 'Ready-to-use creative resources for your gaming identity and broadcasts.',
    icon: Icons.inventory_2_outlined,
    tint: Color(0xFF9A83FF),
    isAsset: true,
  ),
  _StoreCategory(
    key: 'artists',
    title: 'Artists',
    subtitle: 'Creative talent for your esports brand.',
    description: 'Find designers and visual creators for thumbnails, logos, posters and streams.',
    icon: Icons.brush_outlined,
    tint: Color(0xFFFF9F74),
  ),
  _StoreCategory(
    key: 'players',
    title: 'Players',
    subtitle: 'Find players for your competitive roster.',
    description: 'Explore players by game, role and availability. Offers can be monthly or based on a share of prize winnings.',
    icon: Icons.sports_esports_outlined,
    tint: Color(0xFF66A8F2),
  ),
  _StoreCategory(
    key: 'coaches',
    title: 'Coaches',
    subtitle: 'Improve with strategy and performance coaching.',
    description: 'Find coaches for game sense, rotations, scrim reviews and team preparation.',
    icon: Icons.school_outlined,
    tint: Color(0xFF68D6B2),
  ),
  _StoreCategory(
    key: 'orgs',
    title: 'Orgs',
    subtitle: 'Connect with esports organisations.',
    description: 'Discover organisations, competitive programmes and collaboration opportunities.',
    icon: Icons.apartment_outlined,
    tint: Color(0xFFFFC66D),
  ),
  _StoreCategory(
    key: 'management',
    title: 'Management Team',
    subtitle: 'Build the team behind your team.',
    description: 'Find managers and operations professionals for rosters, events and esports projects.',
    icon: Icons.groups_2_outlined,
    tint: Color(0xFFB49BFF),
  ),
];

_StoreCategory _categoryFor(String key) {
  return _storeCategories.firstWhere(
    (category) => category.key == key,
    orElse: () => _storeCategories.first,
  );
}

class _StoreListing {
  const _StoreListing({
    required this.id,
    required this.categoryKey,
    required this.title,
    required this.role,
    required this.description,
    required this.priceValue,
    required this.pricingMode,
    required this.icon,
    this.game = '',
    this.region = 'Remote',
    this.isSample = false,
    this.sellerId = '',
    this.sellerName = 'KOMNIVO seller',
  });

  final String id;
  final String categoryKey;
  final String title;
  final String role;
  final String description;
  final double priceValue;
  final String pricingMode;
  final IconData icon;
  final String game;
  final String region;
  final bool isSample;
  final String sellerId;
  final String sellerName;

  bool get canPurchase => !isSample && (pricingMode == 'fixed' || pricingMode == 'license');

  String get priceLabel {
    final amount = priceValue % 1 == 0 ? priceValue.toStringAsFixed(0) : priceValue.toStringAsFixed(2);
    switch (pricingMode) {
      case 'monthly':
        return '₹$amount / month';
      case 'winnings':
        return '${priceValue.toStringAsFixed(0)}% of prize winnings';
      case 'license':
        return '₹$amount license';
      default:
        return '₹$amount one-time';
    }
  }
}

const _sampleListings = <_StoreListing>[
  _StoreListing(
    id: 'sample-asset-1',
    categoryKey: 'assets',
    title: 'Broadcast Overlay Pack',
    role: 'Stream & tournament graphics',
    description: 'A coordinated overlay set for match broadcasts, score panels and stream scenes.',
    priceValue: 799,
    pricingMode: 'fixed',
    icon: Icons.layers_outlined,
    game: 'Broadcast / Streaming',
    isSample: true,
  ),
  _StoreListing(
    id: 'sample-asset-2',
    categoryKey: 'assets',
    title: 'Player Card Templates',
    role: 'Editable esports profile designs',
    description: 'A reusable set of player-card layouts for roster announcements and social posts.',
    priceValue: 399,
    pricingMode: 'license',
    icon: Icons.badge_outlined,
    game: 'Design assets',
    isSample: true,
  ),
  _StoreListing(
    id: 'sample-artist-1',
    categoryKey: 'artists',
    title: 'PixelForge Studio',
    role: 'Thumbnail & social media artist',
    description: 'Creates gaming thumbnails, roster reveals, match posters and social campaign artwork.',
    priceValue: 3500,
    pricingMode: 'monthly',
    icon: Icons.palette_outlined,
    game: 'Design / Branding',
    isSample: true,
  ),
  _StoreListing(
    id: 'sample-player-1',
    categoryKey: 'players',
    title: 'RAVEN',
    role: 'Entry Fragger · Competitive Player',
    description: 'Aggressive entry playstyle with team-first communication and regular scrim availability.',
    priceValue: 12,
    pricingMode: 'winnings',
    icon: Icons.sports_esports_outlined,
    game: 'Free Fire MAX',
    region: 'India · Remote',
    isSample: true,
  ),
  _StoreListing(
    id: 'sample-player-2',
    categoryKey: 'players',
    title: 'KAI',
    role: 'Rusher · Squad Player',
    description: 'Available for a structured roster with scheduled practice and tournament participation.',
    priceValue: 4500,
    pricingMode: 'monthly',
    icon: Icons.sports_esports_outlined,
    game: 'Free Fire MAX',
    region: 'India · Remote',
    isSample: true,
  ),
  _StoreListing(
    id: 'sample-coach-1',
    categoryKey: 'coaches',
    title: 'Tactical Coach',
    role: 'Strategy & scrim review',
    description: 'Helps teams review rotations, positioning, communication and match decisions.',
    priceValue: 3000,
    pricingMode: 'monthly',
    icon: Icons.school_outlined,
    game: 'Free Fire MAX',
    isSample: true,
  ),
  _StoreListing(
    id: 'sample-org-1',
    categoryKey: 'orgs',
    title: 'Nova Esports Collective',
    role: 'Esports organisation',
    description: 'A sample organisation profile for competitive rosters and tournament collaborations.',
    priceValue: 15,
    pricingMode: 'winnings',
    icon: Icons.apartment_outlined,
    game: 'Multi-game',
    isSample: true,
  ),
  _StoreListing(
    id: 'sample-management-1',
    categoryKey: 'management',
    title: 'Team Operations Lead',
    role: 'Roster & tournament management',
    description: 'Coordinates player availability, registrations, schedules and day-to-day team operations.',
    priceValue: 7500,
    pricingMode: 'monthly',
    icon: Icons.groups_2_outlined,
    game: 'Esports operations',
    isSample: true,
  ),
];

class _StoreCategoryTile extends StatelessWidget {
  const _StoreCategoryTile({required this.category, required this.onTap, required this.narrow});

  final _StoreCategory category;
  final VoidCallback onTap;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 10, vertical: 11),
            decoration: BoxDecoration(
              color: KomnivoTheme.surfaceRaised.withValues(alpha: .48),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: KomnivoTheme.line.withValues(alpha: .7)),
            ),
            child: Row(
              children: [
                Icon(category.icon, color: category.tint, size: 18),
                SizedBox(width: narrow ? 6 : 9),
                Expanded(
                  child: Text(
                    category.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: narrow ? 10 : 12, fontWeight: FontWeight.w800),
                  ),
                ),
                if (!narrow)
                  const Icon(Icons.chevron_right_rounded, color: KomnivoTheme.muted, size: 17),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StoreHeroBanner extends StatelessWidget {
  const _StoreHeroBanner({required this.onExplorePlayers});

  final VoidCallback onExplorePlayers;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // This banner lives in the right pane of a split Store layout, so
        // its own available width—not the full device width—controls density.
        final compact = constraints.maxWidth < 420;
        return Container(
          width: double.infinity,
          padding: EdgeInsets.all(compact ? 15 : 21),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(19),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF282047), Color(0xFF14263A), KomnivoTheme.surface],
        ),
        border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .32)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'BUILD YOUR NEXT LINEUP',
                  style: TextStyle(color: KomnivoTheme.cyan, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.2),
                ),
                const SizedBox(height: 7),
                Text(
                  'Talent, tools and teams.\nAll in one place.',
                  style: TextStyle(fontSize: compact ? 17 : 23, fontWeight: FontWeight.w900, height: 1.12),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Explore the people and resources behind competitive play.',
                  style: TextStyle(color: Colors.white70, fontSize: 10, height: 1.4),
                ),
                const SizedBox(height: 13),
                OutlinedButton(
                  onPressed: onExplorePlayers,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 35),
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    side: BorderSide(color: KomnivoTheme.cyan.withValues(alpha: .55)),
                    textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
                  ),
                  child: const Text('Explore players'),
                ),
              ],
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 12),
            Container(
              width: 108,
              height: 108,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: .05),
                border: Border.all(color: KomnivoTheme.cyan.withValues(alpha: .2), width: 1.5),
              ),
              child: const Icon(Icons.storefront_rounded, size: 52, color: KomnivoTheme.cyan),
            ),
          ] else
            const SizedBox(width: 4),
        ],
        ),
        );
      },
    );
  }
}

class _StoreListingCard extends StatelessWidget {
  const _StoreListingCard({required this.listing, required this.category, required this.onTap});

  final _StoreListing listing;
  final _StoreCategory category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: KomnivoTheme.surface,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: KomnivoTheme.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _ListingAvatar(icon: listing.icon, tint: category.tint, size: 43),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          listing.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          category.title.toUpperCase(),
                          style: TextStyle(color: category.tint, fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: .8),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_outward_rounded, size: 16, color: KomnivoTheme.muted),
                ],
              ),
              const SizedBox(height: 11),
              Text(
                listing.role,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 11, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 5),
              Text(
                listing.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.35),
              ),
              if (listing.game.isNotEmpty) ...[
                const SizedBox(height: 9),
                Row(
                  children: [
                    const Icon(Icons.sports_esports_outlined, color: KomnivoTheme.muted, size: 13),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        listing.game,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9),
                      ),
                    ),
                    if (listing.isSample) const _DemoTag(),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              const Divider(height: 1, color: KomnivoTheme.line),
              const SizedBox(height: 11),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      listing.priceLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
                    ),
                  ),
                  const SizedBox(width: 7),
                  TextButton(
                    onPressed: onTap,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('View', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListingAvatar extends StatelessWidget {
  const _ListingAvatar({required this.icon, required this.tint, this.size = 44});

  final IconData icon;
  final Color tint;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(size * .3),
        border: Border.all(color: tint.withValues(alpha: .3)),
      ),
      child: Icon(icon, color: tint, size: size * .48),
    );
  }
}

class _CategoryPill extends StatelessWidget {
  const _CategoryPill({required this.label, required this.tint});

  final String label;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: tint.withValues(alpha: .28)),
      ),
      child: Text(label, style: TextStyle(color: tint, fontSize: 10, fontWeight: FontWeight.w800)),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: KomnivoTheme.muted, size: 16),
          const SizedBox(width: 9),
          SizedBox(
            width: 105,
            child: Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }
}

class _NewBadge extends StatelessWidget {
  const _NewBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: KomnivoTheme.cyan.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(30),
        ),
        child: const Text(
          'NEW',
          style: TextStyle(color: KomnivoTheme.cyan, fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: .7),
        ),
      );
}

class _SampleLabel extends StatelessWidget {
  const _SampleLabel();

  @override
  Widget build(BuildContext context) => const Text(
        'SAMPLE UI',
        style: TextStyle(color: KomnivoTheme.muted, fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: .7),
      );
}

class _DemoTag extends StatelessWidget {
  const _DemoTag();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(color: KomnivoTheme.surfaceRaised, borderRadius: BorderRadius.circular(5)),
        child: const Text('DEMO', style: TextStyle(color: KomnivoTheme.muted, fontSize: 7, fontWeight: FontWeight.w900)),
      );
}

class _AddStoreListingDialog extends StatefulWidget {
  const _AddStoreListingDialog({this.initialCategory});

  final _StoreCategory? initialCategory;

  @override
  State<_AddStoreListingDialog> createState() => _AddStoreListingDialogState();
}

class _AddStoreListingDialogState extends State<_AddStoreListingDialog> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _role = TextEditingController();
  final _description = TextEditingController();
  final _game = TextEditingController();
  final _region = TextEditingController(text: 'India · Remote');
  final _price = TextEditingController();

  late _StoreCategory _category;
  late String _pricingMode;

  bool get _isAsset => _category.isAsset;

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory ?? _storeCategories.first;
    _pricingMode = _category.isAsset ? 'fixed' : 'monthly';
  }

  @override
  void dispose() {
    _title.dispose();
    _role.dispose();
    _description.dispose();
    _game.dispose();
    _region.dispose();
    _price.dispose();
    super.dispose();
  }

  String get _priceFieldLabel {
    switch (_pricingMode) {
      case 'monthly':
        return 'Monthly price (₹)';
      case 'winnings':
        return 'Share of prize winnings (%)';
      case 'license':
        return 'License price (₹)';
      default:
        return 'One-time price (₹)';
    }
  }

  String get _priceHint => _pricingMode == 'winnings' ? 'e.g. 10' : 'e.g. 4500';

  String? _validatePrice(String? value) {
    final parsed = double.tryParse((value ?? '').trim());
    if (parsed == null || parsed <= 0) return 'Enter a valid amount.';
    if (_pricingMode == 'winnings' && parsed > 100) return 'The percentage cannot exceed 100.';
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final parsedPrice = double.parse(_price.text.trim());
    final category = _category;
    Navigator.of(context).pop(
      _StoreListing(
        id: 'local-${DateTime.now().microsecondsSinceEpoch}',
        categoryKey: category.key,
        title: _title.text.trim(),
        role: _role.text.trim(),
        description: _description.text.trim(),
        priceValue: parsedPrice,
        pricingMode: _pricingMode,
        icon: category.icon,
        game: _game.text.trim(),
        region: _region.text.trim().isEmpty ? 'Remote' : _region.text.trim(),
        isSample: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add to Store'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Publish a talent, service or digital asset listing.',
                  style: TextStyle(color: KomnivoTheme.muted, fontSize: 12),
                ),
                const SizedBox(height: 15),
                DropdownButtonFormField<_StoreCategory>(
                  initialValue: _category,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Store category', prefixIcon: Icon(Icons.category_outlined)),
                  items: _storeCategories.map((category) => DropdownMenuItem(
                    value: category,
                    child: Text(category.title),
                  )).toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _category = value;
                      _pricingMode = value.isAsset ? 'fixed' : 'monthly';
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _title,
                  maxLength: 60,
                  decoration: const InputDecoration(labelText: 'Listing title', hintText: 'e.g. Entry Fragger / Overlay Pack'),
                  validator: (value) => (value?.trim().length ?? 0) < 3 ? 'Enter at least 3 characters.' : null,
                ),
                const SizedBox(height: 7),
                TextFormField(
                  controller: _role,
                  maxLength: 90,
                  decoration: const InputDecoration(labelText: 'Role / Short description', hintText: 'What are you offering?'),
                  validator: (value) => (value?.trim().length ?? 0) < 3 ? 'Add a short description.' : null,
                ),
                const SizedBox(height: 7),
                TextFormField(
                  controller: _description,
                  maxLength: 400,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Details',
                    hintText: 'Describe the offer, experience or included items.',
                    alignLabelWithHint: true,
                  ),
                  validator: (value) => (value?.trim().length ?? 0) < 10 ? 'Enter at least 10 characters.' : null,
                ),
                const SizedBox(height: 7),
                TextFormField(
                  controller: _game,
                  maxLength: 60,
                  decoration: const InputDecoration(labelText: 'Game / Skill (optional)', hintText: 'e.g. Free Fire MAX, Graphic Design'),
                ),
                const SizedBox(height: 7),
                TextFormField(
                  controller: _region,
                  maxLength: 60,
                  decoration: const InputDecoration(labelText: 'Region / Availability', hintText: 'e.g. India · Remote'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _pricingMode,
                  decoration: const InputDecoration(labelText: 'Pricing model', prefixIcon: Icon(Icons.payments_outlined)),
                  items: (_isAsset
                      ? const [
                          DropdownMenuItem(value: 'fixed', child: Text('One-time price')),
                          DropdownMenuItem(value: 'license', child: Text('License price')),
                        ]
                      : const [
                          DropdownMenuItem(value: 'monthly', child: Text('Monthly price')),
                          DropdownMenuItem(value: 'winnings', child: Text('Percentage of prize winnings')),
                        ]).toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _pricingMode = value);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _price,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: _priceFieldLabel,
                    hintText: _priceHint,
                    prefixIcon: Icon(_pricingMode == 'winnings' ? Icons.percent_rounded : Icons.currency_rupee_rounded),
                  ),
                  validator: _validatePrice,
                ),
                const SizedBox(height: 9),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: KomnivoTheme.surfaceRaised,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: KomnivoTheme.line),
                  ),
                  child: const Text(
                    'Published listings become visible to signed-in Store users. Fixed-price assets and licenses can be ordered through WhatsApp; service listings create an inquiry instead of an in-app payment.',
                    style: TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.add_rounded, size: 17),
          label: const Text('Add listing'),
        ),
      ],
    );
  }
}
