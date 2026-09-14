import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/classic_theme.dart';

/// SaaS Overview & Real-Time Platform Analytics Dashboard.
class AdminDashboardView extends ConsumerWidget {
  final VoidCallback? onNavigateToInquiries;
  final VoidCallback? onNavigateToTenants;
  final VoidCallback? onNavigateToFeatures;

  const AdminDashboardView({
    super.key,
    this.onNavigateToInquiries,
    this.onNavigateToTenants,
    this.onNavigateToFeatures,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('organizations').snapshots(),
      builder: (context, orgSnap) {
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('licenses').snapshots(),
          builder: (context, licSnap) {
            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('registration_requests').where('status', isEqualTo: 'PENDING').snapshots(),
              builder: (context, regSnap) {
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance.collection('business_inquiries').where('status', isEqualTo: 'NEW_INQUIRY').snapshots(),
                  builder: (context, inqSnap) {
                    final totalOrgs = orgSnap.hasData ? orgSnap.data!.docs.length : 0;
                    final totalLicenses = licSnap.hasData ? licSnap.data!.docs.length : 0;
                    final pendingTrials = regSnap.hasData ? regSnap.data!.docs.length : 0;
                    final pendingInquiries = inqSnap.hasData ? inqSnap.data!.docs.length : 0;
                    final totalPendingLeads = pendingTrials + pendingInquiries;

                    int activeCount = 0;
                    int expiring7Days = 0;
                    int pureOfflineCount = 0;
                    int paidAnnualCount = 0;
                    int trialCount = 0;

                    final now = DateTime.now();
                    final in7Days = now.add(const Duration(days: 7));

                    if (licSnap.hasData) {
                      for (final doc in licSnap.data!.docs) {
                        final d = doc.data() as Map<String, dynamic>;
                        final status = d['status']?.toString().toUpperCase() ?? 'INACTIVE';
                        final planTier = d['planTier']?.toString().toUpperCase() ?? 'TRIAL';
                        final features = Map<String, dynamic>.from(d['features'] ?? {});

                        if (features['pureOfflineMode'] == true || features['offline'] == true) {
                          pureOfflineCount++;
                        }

                        DateTime? end;
                        if (d['endDate'] is Timestamp) {
                          end = (d['endDate'] as Timestamp).toDate();
                        } else if (d['endDate'] is String) {
                          end = DateTime.tryParse(d['endDate']);
                        }

                        final isExpired = end != null && end.isBefore(now);
                        if (status == 'ACTIVE' && !isExpired) {
                          activeCount++;
                          if (end != null && end.isBefore(in7Days)) {
                            expiring7Days++;
                          }
                          if (planTier == 'YEARLY' || planTier == 'LIFETIME' || planTier == 'MONTHLY') {
                            paidAnnualCount++;
                          } else {
                            trialCount++;
                          }
                        }
                      }
                    }

                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        final isMobile = width < 650;
                        final isTablet = width >= 650 && width < 1050;
                        final isDesktop = width >= 1050;

                        final kpi1 = _buildKpiCard(
                          context,
                          title: 'Active Tenants',
                          value: '$activeCount / $totalOrgs',
                          subtitle: 'Operational stores',
                          icon: Icons.store_mall_directory_rounded,
                          color: const Color(0xFF6366F1),
                          onTap: onNavigateToTenants,
                        );
                        final kpi2 = _buildKpiCard(
                          context,
                          title: 'Expiring in 7 Days',
                          value: '$expiring7Days',
                          subtitle: 'Needs renewal action',
                          icon: Icons.timer_outlined,
                          color: Colors.amber.shade800,
                          onTap: onNavigateToTenants,
                        );
                        final kpi3 = _buildKpiCard(
                          context,
                          title: 'Website Inquiries',
                          value: '$totalPendingLeads',
                          subtitle: '$pendingInquiries Pricing • $pendingTrials Trials',
                          icon: Icons.mark_email_unread_rounded,
                          color: const Color(0xFF0284C7),
                          onTap: onNavigateToInquiries,
                        );
                        final kpi4 = _buildKpiCard(
                          context,
                          title: 'Pure Offline Stations',
                          value: '$pureOfflineCount',
                          subtitle: 'Single-device POS desks',
                          icon: Icons.wifi_off_rounded,
                          color: ClassicTheme.successEmerald,
                          onTap: onNavigateToFeatures,
                        );

                        Widget kpiSection;
                        if (isDesktop) {
                          kpiSection = Row(
                            children: [
                              Expanded(child: kpi1),
                              const SizedBox(width: 14),
                              Expanded(child: kpi2),
                              const SizedBox(width: 14),
                              Expanded(child: kpi3),
                              const SizedBox(width: 14),
                              Expanded(child: kpi4),
                            ],
                          );
                        } else if (isTablet) {
                          kpiSection = Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(child: kpi1),
                                  const SizedBox(width: 14),
                                  Expanded(child: kpi2),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Expanded(child: kpi3),
                                  const SizedBox(width: 14),
                                  Expanded(child: kpi4),
                                ],
                              ),
                            ],
                          );
                        } else {
                          kpiSection = Column(
                            children: [
                              kpi1,
                              const SizedBox(height: 10),
                              kpi2,
                              const SizedBox(height: 10),
                              kpi3,
                              const SizedBox(height: 10),
                              kpi4,
                            ],
                          );
                        }

                        final operationalModesPanel = Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: context.surfaceColor,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: context.borderColor),
                            boxShadow: ClassicTheme.cardShadow(context.isDark),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Subscription & Operational Modes',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: context.textPrimary,
                                    ),
                                  ),
                                  Icon(Icons.tune_rounded, size: 18, color: context.textSecondary),
                                ],
                              ),
                              const SizedBox(height: 16),
                              _buildDistributionBar(
                                context,
                                title: 'Paid Subscriptions (Annual / Monthly)',
                                count: paidAnnualCount,
                                total: totalLicenses > 0 ? totalLicenses : 1,
                                color: const Color(0xFF6366F1),
                              ),
                              const SizedBox(height: 14),
                              _buildDistributionBar(
                                context,
                                title: '14-Day Free Trials',
                                count: trialCount,
                                total: totalLicenses > 0 ? totalLicenses : 1,
                                color: ClassicTheme.successEmerald,
                              ),
                              const SizedBox(height: 14),
                              _buildDistributionBar(
                                context,
                                title: 'Pure Offline Single-Device Clients',
                                count: pureOfflineCount,
                                total: totalLicenses > 0 ? totalLicenses : 1,
                                color: Colors.amber.shade700,
                              ),
                            ],
                          ),
                        );

                        final quickActionsPanel = Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: context.surfaceColor,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: context.borderColor),
                            boxShadow: ClassicTheme.cardShadow(context.isDark),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Quick Administration',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: context.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 14),
                              _quickActionButton(
                                context,
                                icon: Icons.person_add_alt_1_rounded,
                                title: 'Onboard New Organization',
                                subtitle: 'Direct tenant creation',
                                color: ClassicTheme.successEmerald,
                                onTap: onNavigateToTenants,
                              ),
                              const SizedBox(height: 10),
                              _quickActionButton(
                                context,
                                icon: Icons.layers_rounded,
                                title: 'Configure Feature Presets',
                                subtitle: 'Offline vs Cloud allocation',
                                color: const Color(0xFF6366F1),
                                onTap: onNavigateToFeatures,
                              ),
                              const SizedBox(height: 10),
                              _quickActionButton(
                                context,
                                icon: Icons.email_outlined,
                                title: 'Pending Website Queries',
                                subtitle: '$totalPendingLeads leads awaiting call',
                                color: Colors.amber.shade800,
                                onTap: onNavigateToInquiries,
                              ),
                            ],
                          ),
                        );

                        return SingleChildScrollView(
                          padding: EdgeInsets.all(isMobile ? 14 : 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Welcome & Health Banner
                              Container(
                                padding: EdgeInsets.all(isMobile ? 14 : 20),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: context.isDark
                                        ? [const Color(0xFF1E1B4B), const Color(0xFF0F172A)]
                                        : [const Color(0xFFEEF2FF), Colors.white],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: context.isDark ? const Color(0xFF3730A3) : const Color(0xFFC7D2FE),
                                  ),
                                ),
                                child: isMobile
                                    ? Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.all(10),
                                                decoration: BoxDecoration(
                                                  color: ClassicTheme.primaryAccent.withValues(alpha: 0.15),
                                                  borderRadius: BorderRadius.circular(10),
                                                ),
                                                child: const Icon(Icons.rocket_launch_rounded, color: ClassicTheme.primaryAccent, size: 22),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  'Platform Governance & Cloud Health',
                                                  style: TextStyle(
                                                    fontSize: 15.5,
                                                    fontWeight: FontWeight.bold,
                                                    color: context.textPrimary,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            'Real-time SaaS multi-tenant metrics, license telemetry, and customer lead activity across web and POS terminals.',
                                            style: TextStyle(fontSize: 12, color: context.textSecondary),
                                          ),
                                          if (totalPendingLeads > 0) ...[
                                            const SizedBox(height: 12),
                                            SizedBox(
                                              width: double.infinity,
                                              child: ElevatedButton.icon(
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: ClassicTheme.primaryAccentCoral,
                                                  foregroundColor: Colors.white,
                                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                                ),
                                                icon: const Icon(Icons.notifications_active_rounded, size: 16),
                                                label: Text('Review $totalPendingLeads Leads', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                                onPressed: onNavigateToInquiries,
                                              ),
                                            ),
                                          ],
                                        ],
                                      )
                                    : Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: ClassicTheme.primaryAccent.withValues(alpha: 0.15),
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: const Icon(Icons.rocket_launch_rounded, color: ClassicTheme.primaryAccent, size: 28),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  'SmartDine Platform Governance & Cloud Health',
                                                  style: TextStyle(
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.bold,
                                                    color: context.textPrimary,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  'Real-time SaaS multi-tenant metrics, license telemetry, and customer lead activity across web and POS terminals.',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: context.textSecondary,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (totalPendingLeads > 0)
                                            ElevatedButton.icon(
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: ClassicTheme.primaryAccentCoral,
                                                foregroundColor: Colors.white,
                                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                              ),
                                              icon: const Icon(Icons.notifications_active_rounded, size: 16),
                                              label: Text('Review $totalPendingLeads Leads', style: const TextStyle(fontWeight: FontWeight.bold)),
                                              onPressed: onNavigateToInquiries,
                                            ),
                                        ],
                                      ),
                              ),
                              const SizedBox(height: 20),

                              // Responsive KPI Cards
                              kpiSection,
                              const SizedBox(height: 20),

                              // Operational Breakdown & Quick Tools
                              if (width >= 950)
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(flex: 3, child: operationalModesPanel),
                                    const SizedBox(width: 18),
                                    Expanded(flex: 2, child: quickActionsPanel),
                                  ],
                                )
                              else
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    operationalModesPanel,
                                    const SizedBox(height: 18),
                                    quickActionsPanel,
                                  ],
                                ),
                              const SizedBox(height: 20),

                          // Live System Audit Stream Preview
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: context.surfaceColor,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: context.borderColor),
                              boxShadow: ClassicTheme.cardShadow(context.isDark),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.shield_outlined, size: 18, color: Color(0xFF10B981)),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Recent Governance & Audit Activity',
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold,
                                            color: context.textPrimary,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Text('Live', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald)),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                StreamBuilder<QuerySnapshot>(
                                  stream: FirebaseFirestore.instance
                                      .collection('audit_logs')
                                      .orderBy('timestamp', descending: true)
                                      .limit(5)
                                      .snapshots(),
                                  builder: (context, auditSnap) {
                                    if (!auditSnap.hasData || auditSnap.data!.docs.isEmpty) {
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 16),
                                        child: Center(
                                          child: Text('No audit events logged yet.', style: TextStyle(color: context.textSecondary, fontSize: 12.5)),
                                        ),
                                      );
                                    }
                                    return Column(
                                      children: auditSnap.data!.docs.map((doc) {
                                        final d = doc.data() as Map<String, dynamic>;
                                        final action = d['action'] ?? 'SYSTEM_EVENT';
                                        final details = d['details'] ?? '';
                                        final by = d['by'] ?? 'admin';
                                        return Container(
                                          margin: const EdgeInsets.only(bottom: 8),
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: context.canvasColor,
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: context.borderColor),
                                          ),
                                          child: Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.all(5),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFF6366F1).withValues(alpha: 0.12),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: const Icon(Icons.history_toggle_off_rounded, size: 14, color: Color(0xFF6366F1)),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Text(
                                                  '$action: $details ($by)',
                                                  style: TextStyle(fontSize: 12, color: context.textPrimary),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                    );
                                  },
                                ),
                              ],
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
      },
    );
      },
    );
  }

  Widget _buildKpiCard(
    BuildContext context, {
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.borderColor),
          boxShadow: ClassicTheme.cardShadow(context.isDark),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: Colors.grey),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              value,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              title,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              ),
            ),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: context.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDistributionBar(
    BuildContext context, {
    required String title,
    required int count,
    required int total,
    required Color color,
  }) {
    final double pct = (count / (total > 0 ? total : 1)).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: TextStyle(fontSize: 12.5, color: context.textPrimary, fontWeight: FontWeight.w500)),
            Text('$count (${(pct * 100).toInt()}%)', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct,
            backgroundColor: context.canvasColor,
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 8,
          ),
        ),
      ],
    );
  }

  Widget _quickActionButton(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.canvasColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.borderColor),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: context.textPrimary)),
                  Text(subtitle, style: TextStyle(fontSize: 11, color: context.textSecondary)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 16, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
