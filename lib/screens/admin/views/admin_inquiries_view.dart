import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/classic_theme.dart';
import '../../../utils/ui_feedback.dart';
import '../admin_models.dart';

/// Redesigned, perfectly aligned Website Inquiries & Pricing Leads desk.
/// Features dual-feed support for Commercial Plan inquiries and Free Trial registrations,
/// real-time status updates, quick-contact actions, and 1-click tenant onboarding.
class AdminInquiriesView extends ConsumerStatefulWidget {
  final Function(UnifiedClientLead lead)? onOnboardLead;

  const AdminInquiriesView({super.key, this.onOnboardLead});

  @override
  ConsumerState<AdminInquiriesView> createState() => _AdminInquiriesViewState();
}

class _AdminInquiriesViewState extends ConsumerState<AdminInquiriesView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _selectedFilter = 'PENDING'; // 'ALL', 'PENDING', 'COMMERCIAL', 'TRIALS', 'CONVERTED'
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _makeCall(String phone) async {
    final clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return;
    final uri = Uri.parse('tel:$clean');
    try {
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    } catch (_) {}
  }

  Future<void> _openWhatsApp(String phone, String name, String brand) async {
    var clean = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.length == 10) clean = '91$clean';
    if (clean.isEmpty) return;
    final msg = Uri.encodeComponent(
      'Hello $name! Greetings from SmartDine POS. We received your request for "$brand". We would love to assist with your demo and onboarding.',
    );
    final uri = Uri.parse('https://wa.me/$clean?text=$msg');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _sendEmail(String email, String brand) async {
    if (email.isEmpty) return;
    final subject = Uri.encodeComponent('SmartDine POS Demonstration & Onboarding: $brand');
    final uri = Uri.parse('mailto:$email?subject=$subject');
    try {
      await launchUrl(uri);
    } catch (_) {}
  }

  Future<void> _updateLeadStatus(UnifiedClientLead lead, String newStatus) async {
    final collection = lead.isTrial ? 'registration_requests' : 'business_inquiries';
    try {
      await FirebaseFirestore.instance.collection(collection).doc(lead.id).update({
        'status': newStatus,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        AppToast.showSuccess(context, 'Lead marked as $newStatus');
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to update lead: $e');
      }
    }
  }

  Color _getStatusColor(String status) {
    switch (status.toUpperCase()) {
      case 'PENDING':
      case 'NEW_INQUIRY':
      case 'NEW':
        return ClassicTheme.warningAmber;
      case 'APPROVED':
      case 'CONVERTED':
      case 'ACTIVE':
        return ClassicTheme.successEmerald;
      case 'CONTACTED':
        return ClassicTheme.infoBlue;
      case 'REJECTED':
      case 'CANCELLED':
        return ClassicTheme.dangerRed;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('registration_requests').snapshots(),
      builder: (context, trialSnap) {
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('business_inquiries').snapshots(),
          builder: (context, inqSnap) {
            final List<UnifiedClientLead> leads = [];

            // 1. Parse Trials
            if (trialSnap.hasData) {
              for (final doc in trialSnap.data!.docs) {
                final d = doc.data() as Map<String, dynamic>;
                leads.add(UnifiedClientLead.fromTrial(doc.id, d));
              }
            }

            // 2. Parse Inquiries
            if (inqSnap.hasData) {
              for (final doc in inqSnap.data!.docs) {
                final d = doc.data() as Map<String, dynamic>;
                leads.add(UnifiedClientLead.fromInquiry(doc.id, d));
              }
            }

            // Sort newest first
            leads.sort((a, b) {
              if (a.createdAt == null && b.createdAt == null) return 0;
              if (a.createdAt == null) return 1;
              if (b.createdAt == null) return -1;
              return b.createdAt!.compareTo(a.createdAt!);
            });

            // Metrics
            final totalCount = leads.length;
            final pendingCount = leads.where((l) => l.isPending).length;
            final commercialCount = leads.where((l) => !l.isTrial).length;
            final trialCount = leads.where((l) => l.isTrial).length;

            // Apply Filters
            List<UnifiedClientLead> filtered = leads;
            if (_selectedFilter == 'PENDING') {
              filtered = filtered.where((l) => l.isPending).toList();
            } else if (_selectedFilter == 'COMMERCIAL') {
              filtered = filtered.where((l) => !l.isTrial).toList();
            } else if (_selectedFilter == 'TRIALS') {
              filtered = filtered.where((l) => l.isTrial).toList();
            } else if (_selectedFilter == 'CONVERTED') {
              filtered = filtered.where((l) => l.status == 'APPROVED' || l.status == 'CONVERTED').toList();
            }

            // Apply Search
            if (_searchQuery.isNotEmpty) {
              final q = _searchQuery.toLowerCase();
              filtered = filtered.where((l) =>
                  l.brandName.toLowerCase().contains(q) ||
                  l.clientName.toLowerCase().contains(q) ||
                  l.phone.toLowerCase().contains(q) ||
                  l.email.toLowerCase().contains(q) ||
                  l.city.toLowerCase().contains(q) ||
                  l.selectedPlan.toLowerCase().contains(q)).toList();
            }

            return LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final isMobile = width < 650;
                final isDesktop = width >= 1050;

                final m1 = _buildMetricCard(
                  title: 'Total Leads',
                  count: totalCount,
                  icon: Icons.mark_email_unread_rounded,
                  color: ClassicTheme.secondaryAccent,
                  isMobile: isMobile,
                );
                final m2 = _buildMetricCard(
                  title: 'Needs Action',
                  count: pendingCount,
                  icon: Icons.hourglass_top_rounded,
                  color: ClassicTheme.warningAmber,
                  isMobile: isMobile,
                );
                final m3 = _buildMetricCard(
                  title: 'Pricing Queries',
                  count: commercialCount,
                  icon: Icons.business_center_rounded,
                  color: ClassicTheme.infoBlue,
                  isMobile: isMobile,
                );
                final m4 = _buildMetricCard(
                  title: 'Free Trials',
                  count: trialCount,
                  icon: Icons.verified_user_rounded,
                  color: ClassicTheme.successEmerald,
                  isMobile: isMobile,
                );

                Widget metricSection;
                if (isDesktop) {
                  metricSection = Row(
                    children: [
                      Expanded(child: m1),
                      const SizedBox(width: 12),
                      Expanded(child: m2),
                      const SizedBox(width: 12),
                      Expanded(child: m3),
                      const SizedBox(width: 12),
                      Expanded(child: m4),
                    ],
                  );
                } else {
                  metricSection = Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: m1),
                          SizedBox(width: isMobile ? 8 : 12),
                          Expanded(child: m2),
                        ],
                      ),
                      SizedBox(height: isMobile ? 8 : 12),
                      Row(
                        children: [
                          Expanded(child: m3),
                          SizedBox(width: isMobile ? 8 : 12),
                          Expanded(child: m4),
                        ],
                      ),
                    ],
                  );
                }

                final searchField = TextField(
                  controller: _searchCtrl,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search leads by restaurant name, contact, phone, city, or plan...',
                    hintStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                    prefixIcon: Icon(Icons.search_rounded, size: 18, color: context.textSecondary),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: context.inputFill,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                  ),
                  onChanged: (v) => setState(() => _searchQuery = v.trim()),
                );

                final filterChipsList = [
                  _filterChip('PENDING', 'Pending ($pendingCount)'),
                  _filterChip('COMMERCIAL', 'Pricing Queries'),
                  _filterChip('TRIALS', 'Free Trials'),
                  _filterChip('CONVERTED', 'Converted'),
                  _filterChip('ALL', 'All Leads'),
                ];

                return Padding(
                  padding: EdgeInsets.all(isMobile ? 14 : 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Responsive Metric Cards
                      metricSection,
                      const SizedBox(height: 16),

                      // Responsive Search & Filter Bar
                      if (width >= 900)
                        Row(
                          children: [
                            Expanded(child: searchField),
                            const SizedBox(width: 12),
                            Wrap(
                              spacing: 8,
                              children: filterChipsList,
                            ),
                          ],
                        )
                      else
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            searchField,
                            const SizedBox(height: 10),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: filterChipsList
                                    .map((chip) => Padding(
                                          padding: const EdgeInsets.only(right: 8),
                                          child: chip,
                                        ))
                                    .toList(),
                              ),
                            ),
                          ],
                        ),
                      const SizedBox(height: 16),

                      // Leads List View
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.inbox_outlined, size: 48, color: context.textSecondary.withValues(alpha: 0.5)),
                                    const SizedBox(height: 10),
                                    Text(
                                      'No requests found matching your filter criteria.',
                                      style: TextStyle(color: context.textSecondary, fontSize: 13),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.separated(
                                itemCount: filtered.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 14),
                                itemBuilder: (context, index) {
                                  final lead = filtered[index];
                                  return _buildLeadCard(lead);
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _filterChip(String filterKey, String label) {
    final isSelected = _selectedFilter == filterKey;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          color: isSelected ? Colors.white : context.textPrimary,
        ),
      ),
      selected: isSelected,
      selectedColor: ClassicTheme.primaryAccent,
      backgroundColor: context.surfaceColor,
      side: BorderSide(color: isSelected ? ClassicTheme.primaryAccent : context.borderColor),
      onSelected: (_) => setState(() => _selectedFilter = filterKey),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required int count,
    required IconData icon,
    required Color color,
    bool isMobile = false,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 16, vertical: isMobile ? 10 : 14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(isMobile ? 7 : 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: isMobile ? 18 : 22),
          ),
          SizedBox(width: isMobile ? 8 : 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  count.toString(),
                  style: TextStyle(
                    fontSize: isMobile ? 17 : 20,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                ),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: isMobile ? 10.5 : 11.5,
                    color: context.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeadCard(UnifiedClientLead lead) {
    final isTrial = lead.isTrial;
    final typeColor = isTrial ? ClassicTheme.successEmerald : ClassicTheme.secondaryAccent;
    final statusColor = _getStatusColor(lead.status);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: lead.isPending ? ClassicTheme.warningAmber.withValues(alpha: 0.4) : context.borderColor,
          width: lead.isPending ? 1.5 : 1,
        ),
        boxShadow: ClassicTheme.cardShadow(context.isDark),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Brand Name, Type Badge, Plan Badge, Status & Date
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: typeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isTrial ? Icons.verified_user_rounded : Icons.business_center_rounded,
                  color: typeColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            lead.brandName.isNotEmpty ? lead.brandName : lead.clientName,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: context.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (lead.brandName.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '• ${lead.clientName}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: context.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: typeColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            isTrial ? '14-Day Free Trial' : lead.selectedPlan,
                            style: TextStyle(
                              color: typeColor,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Text(
                          lead.businessCategory,
                          style: TextStyle(fontSize: 12, color: context.textSecondary),
                        ),
                        if (lead.outlets.isNotEmpty)
                          Text('• ${lead.outlets}', style: TextStyle(fontSize: 12, color: context.textSecondary)),
                        if (lead.stations.isNotEmpty)
                          Text('• ${lead.stations}', style: TextStyle(fontSize: 12, color: context.textSecondary)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),

              // Status Badge & Date
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      lead.status,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (lead.createdAt != null)
                    Text(
                      '${lead.createdAt!.day}/${lead.createdAt!.month}/${lead.createdAt!.year} ${lead.createdAt!.hour.toString().padLeft(2, '0')}:${lead.createdAt!.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(fontSize: 12, color: context.textSecondary),
                    ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),
          Divider(color: context.borderColor, height: 1),
          const SizedBox(height: 10),

          // Row 2: Contact Details & Chips
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (lead.phone.isNotEmpty)
                _infoChip(Icons.phone_android_rounded, lead.phone),
              if (lead.email.isNotEmpty)
                _infoChip(Icons.mail_outline_rounded, lead.email),
              if (lead.city.isNotEmpty)
                _infoChip(Icons.location_on_outlined, lead.city),
            ],
          ),

          // Requirements / Notes Box
          if (lead.requirements.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: context.isDark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context.borderColor),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.notes_rounded, size: 14, color: context.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      lead.requirements,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 12,
                        height: 1.35,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 14),

          // Action Buttons Bar
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Contact Channels
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (lead.phone.isNotEmpty) ...[
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        side: BorderSide(color: context.borderColor),
                      ),
                      icon: const Icon(Icons.call_rounded, size: 14, color: ClassicTheme.infoBlue),
                      label: const Text('Call', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      onPressed: () => _makeCall(lead.phone),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      icon: const Icon(Icons.chat_bubble_outline_rounded, size: 14),
                      label: const Text('WhatsApp', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      onPressed: () => _openWhatsApp(lead.phone, lead.clientName, lead.brandName),
                    ),
                  ],
                  if (lead.email.isNotEmpty)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        side: BorderSide(color: context.borderColor),
                      ),
                      icon: Icon(Icons.mail_rounded, size: 14, color: ClassicTheme.secondaryAccent),
                      label: const Text('Email', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      onPressed: () => _sendEmail(lead.email, lead.brandName),
                    ),
                ],
              ),

              // Onboard & Status Management
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (lead.isPending)
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: context.textSecondary,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      ),
                      child: const Text('Mark Contacted', style: TextStyle(fontSize: 12)),
                      onPressed: () => _updateLeadStatus(lead, 'CONTACTED'),
                    ),
                  if (lead.isOnboarded)
                    // Already a tenant -- by the web trial handler or by an
                    // earlier approval. Onboarding again would make a second
                    // organisation for the same person and trip the
                    // duplicate-e-mail guard on the way.
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: ClassicTheme.successEmerald.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.verified_rounded, size: 15, color: ClassicTheme.successEmerald),
                          const SizedBox(width: 6),
                          Text(
                            'Onboarded \u00b7 ${lead.organizationId}',
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald),
                          ),
                        ],
                      ),
                    )
                  else
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ClassicTheme.successEmerald,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.person_add_alt_1_rounded, size: 15),
                      label: const Text('Onboard as Tenant', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      onPressed: () {
                        if (widget.onOnboardLead != null) {
                          widget.onOnboardLead!(lead);
                        }
                      },
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: context.textSecondary),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: context.textPrimary,
          ),
        ),
      ],
    );
  }
}
