use std::{
    cmp::min,
    collections::{BTreeMap, BTreeSet},
};

use super::{fitmatch, implantmatch, skills::SkillTier};
use crate::data::{categories, fits::DoctrineFit, skills::Skills};
use eve_data_core::{FitError, Fitting, TypeDB, TypeID};
use serde::Serialize;

#[derive(Debug)]
pub struct Output {
    pub approved: bool,
    pub tags:     Vec<&'static str>,
    pub category: String,
    pub errors:   Vec<String>,

    pub analysis: Option<PubAnalysis>,
}

#[derive(Debug, Serialize)]
pub struct PubAnalysis {
    name:          String,
    missing:       BTreeMap<TypeID, i64>,
    extra:         BTreeMap<TypeID, i64>,
    cargo_missing: BTreeMap<TypeID, i64>,
    downgraded:    BTreeMap<TypeID, BTreeMap<TypeID, i64>>,
}

pub struct PilotData<'a> {
    pub implants:      &'a [TypeID],
    pub time_in_fleet: i64,
    pub skills:        &'a Skills,
    pub access_keys:   &'a BTreeSet<String>,
}

pub struct FitChecker<'a> {
    approved:     bool,
    category:     Option<String>,
    badges:       &'a Vec<String>,
    fit:          &'a Fitting,
    doctrine_fit: Option<&'static DoctrineFit>,
    pilot:        &'a PilotData<'a>,

    tags:     BTreeSet<&'static str>,
    errors:   Vec<String>,
    analysis: Option<PubAnalysis>,
}

impl<'a> FitChecker<'a> {
    pub fn check(
        pilot: &PilotData<'_>,
        fit: &Fitting,
        badges: &Vec<String>,
    ) -> Result<Output, FitError> {
        let mut checker = FitChecker {
            approved: true,
            category: None,
            badges,
            fit,
            doctrine_fit: None,
            pilot,
            tags: BTreeSet::new(),
            errors: Vec::new(),
            analysis: None,
        };

        checker.check_skill_reqs()?;
        checker.check_module_skills()?;
        checker.check_fit();
        checker.check_fit_implants_reqs();
        checker.check_logi_implants();
        checker.set_category();
        checker.add_snowflake_tags();
        checker.add_implant_tag();
        checker.merge_tags();
        checker.check_time_in_fleet();

        checker.finish()
    }

    fn check_skill_reqs_tier(&self, tier: SkillTier) -> Result<bool, FitError> {
        let ship_name = TypeDB::name_of(self.fit.hull)?;
        if let Some(reqs) = super::skills::skill_data().requirements.get(&ship_name) {
            for (&skill_id, tiers) in reqs {
                if let Some(req) = tiers.get(tier) {
                    if self.pilot.skills.get(skill_id) < req {
                        return Ok(false);
                    }
                }
            }
            Ok(true)
        } else {
            Ok(false)
        }
    }

    fn check_skill_reqs(&mut self) -> Result<(), FitError> {
        let skill_tier = if self.check_skill_reqs_tier(SkillTier::Gold)? {
            "gold"
        } else if self.check_skill_reqs_tier(SkillTier::Elite)? {
            "elite"
        } else if self.check_skill_reqs_tier(SkillTier::Min)? {
            "basic"
        } else {
            "starter"
        };

        if skill_tier == "starter" {
            self.tags.insert("STARTER-SKILLS");
        } else if skill_tier == "gold" {
            self.tags.insert("GOLD-SKILLS");
        } else if skill_tier == "elite" {
            self.tags.insert("ELITE-SKILLS");
        }

        Ok(())
    }

    fn check_module_skills(&mut self) -> Result<(), FitError> {
        let mut module_ids = vec![self.fit.hull];
        for &module_id in self.fit.modules.keys() {
            module_ids.push(module_id);
        }
        let types = TypeDB::load_types(&module_ids)?;

        for (_type_id, typedata) in types {
            let typedata = typedata.expect("Fit was checked so this can't happen?");
            for (&skill_id, &level) in &typedata.skill_requirements {
                if self.pilot.skills.get(skill_id) < level {
                    self.errors
                        .push(format!("Missing skills to online/use '{}'", typedata.name));
                }
            }
        }
        Ok(())
    }

    fn check_logi_implants(&mut self) {
        if (self.fit.hull == type_id!("Nestor") || self.fit.hull == type_id!("Guardian"))
            && !self.pilot.implants.contains(&type_id!("% EM-806"))
        {
            self.tags.insert("NO-EM-806");
        }
    }

    fn check_fit(&mut self) {
        if let Some((doctrine_fit, mut diff)) = fitmatch::find_fit(self.fit) {
            self.doctrine_fit = Some(doctrine_fit);

            if doctrine_fit.name.contains("ANTIGANK") {
                // For ANTIGANK, we consider all upgraded mods actually downgrades, since price is an issue
                diff.module_downgraded.append(&mut diff.module_upgraded);
                self.tags.insert("ANTIGANK");
            }

            let fit_ok = diff.module_downgraded.is_empty() && diff.module_missing.is_empty();

            if !(diff.cargo_missing.is_empty() && fit_ok) {
                self.approved = false;
            }
            if doctrine_fit.name.contains("STARTER") {
                self.tags.insert("STARTER-FIT");
            }
            if fit_ok && doctrine_fit.name.contains("ELITE") {
                self.tags.insert("ELITE-FIT");
            }

            self.analysis = Some(PubAnalysis {
                name:          doctrine_fit.name.clone(),
                missing:       diff.module_missing,
                extra:         diff.module_extra,
                downgraded:    diff.module_downgraded,
                cargo_missing: diff.cargo_missing,
            });
        } else {
            self.approved = false;
        }
    }

    fn check_time_in_fleet(&mut self) {
        let pilot_elite = self.tags.contains("ELITE")
            || self.tags.contains("ELITE-GOLD")
            || self.tags.contains("WEB")
            || self.tags.contains("BASTION");
        if self.fit.hull == type_id!("Vindicator") {
            if self.pilot.time_in_fleet > (200 * 3600) && !pilot_elite {
                self.approved = false;
            }
        } else if self.fit.hull == type_id!("Paladin") || self.fit.hull == type_id!("Kronos") {
            if self.pilot.time_in_fleet > (250 * 3600) && !pilot_elite {
                self.approved = false;
            }
        } else if self.pilot.time_in_fleet > (150 * 3600) && !pilot_elite {
            self.approved = false;
        }
    }

    fn check_fit_implants_reqs(&mut self) {
        if let Some(doctrine_fit) = self.doctrine_fit {
            let set_tag = implantmatch::detect_base_set(self.pilot.implants).unwrap_or("");
            if set_tag != "SAVIOR" {
                let mut implants_nok = "";
                if doctrine_fit.name.contains("ASCENDANCY") && set_tag != "WARPSPEED" {
                    implants_nok = "Ascendancy";
                } else if doctrine_fit.name.contains("HYBRID") && set_tag != "AMULET" {
                    let implants = [
                        type_id!("High-grade Amulet Alpha"),
                        type_id!("High-grade Amulet Beta"),
                        type_id!("High-grade Amulet Delta"),
                        type_id!("High-grade Amulet Epsilon"),
                        type_id!("High-grade Amulet Gamma"),
                    ];
                    for implant in implants {
                        if !self.pilot.implants.contains(&implant) {
                            implants_nok = "Hybrid";
                        }
                    }
                } else if doctrine_fit.name.contains("AMULET") && set_tag != "AMULET" {
                    implants_nok = "Amulet";
                }
                if implants_nok != "" {
                    self.errors.push(format!(
                        "Missing required implants to fly {} fit",
                        implants_nok
                    ));
                }
            }
        }
    }

    fn add_implant_tag(&mut self) {
        if let Some(doctrine_fit) = self.doctrine_fit {
            // Implant badge will show if you have 1-9
            if let Some(set_tag) = implantmatch::detect_set(self.fit.hull, self.pilot.implants) {
                // all non tagged fits are ascendancy (warpspeed)
                // logi cruisers are an expection, they can fly whatever they want
                // full amulet is still elite on hybrid fit
                if set_tag == "SAVIOR" {
                    self.tags.insert("SAVIOR");
                } else if doctrine_fit.name.contains(set_tag)
                    || (set_tag == "WARPSPEED"
                        && !(doctrine_fit.name.contains("AMULET")
                            || doctrine_fit.name.contains("HYBRID")))
                    || self.fit.hull == type_id!("Oneiros")
                    || self.fit.hull == type_id!("Guardian")
                    || (set_tag == "AMULET" && doctrine_fit.name.contains("HYBRID"))
                {
                    self.tags.insert(set_tag);
                    // give warning if you have all but slot 10 or wrong slot for that ship
                    if implantmatch::detect_slot10(self.fit.hull, self.pilot.implants).is_none() {
                        self.tags.insert("NO-SLOT10");
                    }
                    if set_tag == "AMULET" && doctrine_fit.name.contains("HYBRID") {
                        self.tags.insert("SLOW");
                    }
                }
            }
        }
    }

    fn set_category(&mut self) {
        let mut category =
            categories::categorize(self.fit).unwrap_or_else(|| "starter".to_string());
        if self.tags.contains("STARTER-SKILLS") || self.tags.contains("STARTER-FIT") {
            if category == "logi" {
                self.approved = false;
            } else {
                category = "starter".to_string();
            }
        }
        self.category = Some(category);
    }

    fn add_snowflake_tags(&mut self) {
        if self.pilot.access_keys.contains("waitlist-tag:HQ-FC") {
            self.tags.insert("HQ-FC");
        } else if self.pilot.access_keys.contains("waitlist-tag:TRAINEE") {
            self.tags.insert("TRAINEE");
        } else {
            // To save space on the XUP card,
            // don't show these badges for FCs
            if self.fit.hull == type_id!("Nestor") {
                if self.badges.contains(&String::from("LOGI")) {
                    self.tags.insert("LOGI");
                }
                if self.badges.contains(&String::from("RETIRED-LOGI")) {
                    self.tags.insert("RETIRED-LOGI");
                }
            }

            if self.fit.hull == type_id!("Vindicator") && self.badges.contains(&String::from("WEB"))
            {
                self.tags.insert("WEB-SPECIALIST");
            }

            if (self.fit.hull == type_id!("Kronos") || self.fit.hull == type_id!("Paladin"))
                && self.badges.contains(&String::from("BASTION"))
            {
                self.tags.insert("BASTION-SPECIALIST");
            }
        }
    }

    fn merge_tags(&mut self) {
        if self.tags.contains("ELITE-FIT") {
            if ["WARPSPEED", "HYBRID", "AMULET"]
                .iter()
                .any(|e| self.tags.contains(e))
                || self.tags.contains("SAVIOR")
            {
                if self.tags.contains("ELITE-SKILLS") {
                    self.tags.remove("ELITE-FIT");
                    self.tags.remove("ELITE-SKILLS");
                    if self.tags.contains("BASTION-SPECIALIST") {
                        self.tags.remove("BASTION-SPECIALIST");
                        self.tags.insert("BASTION");
                    } else if self.tags.contains("WEB-SPECIALIST") {
                        self.tags.remove("WEB-SPECIALIST");
                        self.tags.insert("WEB");
                    } else {
                        self.tags.insert("ELITE");
                    }
                } else if self.tags.contains("GOLD-SKILLS") {
                    self.tags.remove("ELITE-FIT");
                    self.tags.remove("GOLD-SKILLS");
                    self.tags.insert("ELITE-GOLD");
                    if self.tags.contains("BASTION-SPECIALIST") {
                        self.tags.remove("BASTION-SPECIALIST");
                        self.tags.insert("BASTION");
                    } else if self.tags.contains("WEB-SPECIALIST") {
                        self.tags.remove("WEB-SPECIALIST");
                        self.tags.insert("WEB");
                    }
                }
            } else if self.tags.contains("ANTIGANK") {
                // ANTIGANK fleet clutter cleanup
                self.tags.remove("ELITE-FIT");
            }
        } else if self.tags.contains("STARTER-SKILLS") || self.tags.contains("STARTER-FIT") {
            self.tags.remove("STARTER-FIT");
            self.tags.remove("STARTER-SKILLS");
            self.tags.insert("STARTER");
        }
    }

    fn finish(self) -> Result<Output, FitError> {
        Ok(Output {
            approved: self.approved,
            tags:     self.tags.into_iter().collect(),
            errors:   self.errors,
            category: self.category.expect("Category not assigned"),
            analysis: self.analysis,
        })
    }
}
